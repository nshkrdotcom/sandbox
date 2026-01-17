defmodule Sandbox.ResourceMonitor do
  @moduledoc """
  Monitors and enforces resource limits for sandboxes.
  """

  use GenServer

  require Logger

  alias Sandbox.Config

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register_sandbox(sandbox_id, pid, limits \\ %{}, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:register_sandbox, sandbox_id, pid, limits, call_opts})
  end

  def unregister_sandbox(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:unregister_sandbox, sandbox_id})
  end

  def sample_usage(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:sample_usage, sandbox_id})
  end

  def check_limits(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:check_limits, sandbox_id})
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name) || Config.table_name(:sandbox_resources, opts)

    ensure_table(table_name, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    Logger.debug("ResourceMonitor starting with opts: #{inspect(opts)}")

    {:ok, %{sandboxes: %{}, table_name: table_name}}
  end

  @impl true
  def handle_call({:register_sandbox, sandbox_id, pid, limits, _opts}, _from, state) do
    cond do
      not is_binary(sandbox_id) ->
        {:reply, {:error, :invalid_sandbox_id}, state}

      not is_pid(pid) ->
        {:reply, {:error, :invalid_pid}, state}

      not Process.alive?(pid) ->
        {:reply, {:error, :process_dead}, state}

      Map.has_key?(state.sandboxes, sandbox_id) ->
        {:reply, {:error, :already_registered}, state}

      true ->
        normalized_limits = normalize_limits(limits)
        started_at = System.monotonic_time(:millisecond)
        usage = build_usage(pid, started_at)

        :ets.insert(state.table_name, {sandbox_id, usage})

        updated_state = %{
          state
          | sandboxes:
              Map.put(state.sandboxes, sandbox_id, %{
                pid: pid,
                limits: normalized_limits,
                started_at: started_at
              })
        }

        {:reply, :ok, updated_state}
    end
  end

  def handle_call({:unregister_sandbox, sandbox_id}, _from, state) do
    case Map.pop(state.sandboxes, sandbox_id) do
      {nil, _sandboxes} ->
        {:reply, {:error, :not_found}, state}

      {_entry, updated_sandboxes} ->
        :ets.delete(state.table_name, sandbox_id)
        {:reply, :ok, %{state | sandboxes: updated_sandboxes}}
    end
  end

  def handle_call({:sample_usage, sandbox_id}, _from, state) do
    {:reply, sample_usage_reply(sandbox_id, state), state}
  end

  def handle_call({:check_limits, sandbox_id}, _from, state) do
    {:reply, check_limits_reply(sandbox_id, state), state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_info, state) do
    {:noreply, state}
  end

  defp normalize_limits(limits) when is_map(limits), do: limits
  defp normalize_limits(limits) when is_list(limits), do: Map.new(limits)
  defp normalize_limits(_), do: %{}

  defp sample_usage_reply(sandbox_id, state) do
    with %{pid: pid, started_at: started_at} <- Map.get(state.sandboxes, sandbox_id),
         true <- Process.alive?(pid) do
      usage = build_usage(pid, started_at)
      :ets.insert(state.table_name, {sandbox_id, usage})
      {:ok, usage}
    else
      nil -> {:error, :not_found}
      false -> {:error, :process_dead}
    end
  end

  defp check_limits_reply(sandbox_id, state) do
    with %{pid: pid, started_at: started_at, limits: limits} <-
           Map.get(state.sandboxes, sandbox_id),
         true <- Process.alive?(pid) do
      usage = build_usage(pid, started_at)
      :ets.insert(state.table_name, {sandbox_id, usage})
      limits_reply(usage, limits)
    else
      nil -> {:error, :not_found}
      false -> {:error, :process_dead}
    end
  end

  defp limits_reply(usage, limits) do
    case exceeded_limits(usage, limits) do
      [] -> :ok
      exceeded -> {:error, {:limit_exceeded, exceeded}}
    end
  end

  defp build_usage(pid, started_at) do
    pids = collect_pids(pid)

    {memory, message_queue} =
      Enum.reduce(pids, {0, 0}, fn process, {memory_acc, queue_acc} ->
        case Process.info(process, [:memory, :message_queue_len]) do
          nil ->
            {memory_acc, queue_acc}

          info ->
            memory_value = Keyword.get(info, :memory, 0)
            queue_value = Keyword.get(info, :message_queue_len, 0)
            {memory_acc + memory_value, queue_acc + queue_value}
        end
      end)

    uptime = max(System.monotonic_time(:millisecond) - started_at, 0)

    %{
      memory: memory,
      processes: length(pids),
      message_queue: message_queue,
      uptime: uptime
    }
  end

  defp collect_pids(pid) do
    {pids, _visited} = do_collect_pids(pid, MapSet.new())
    Enum.reverse(pids)
  end

  defp do_collect_pids(pid, visited) do
    cond do
      not is_pid(pid) ->
        {[], visited}

      not Process.alive?(pid) ->
        {[], visited}

      MapSet.member?(visited, pid) ->
        {[], visited}

      true ->
        updated_visited = MapSet.put(visited, pid)
        child_pids = supervisor_child_pids(pid)

        {descendants, final_visited} =
          Enum.reduce(child_pids, {[], updated_visited}, fn child_pid, {acc, acc_visited} ->
            {child_descendants, new_visited} = do_collect_pids(child_pid, acc_visited)

            merged =
              Enum.reduce(child_descendants, acc, fn descendant, descendant_acc ->
                [descendant | descendant_acc]
              end)

            {merged, new_visited}
          end)

        {[pid | descendants], final_visited}
    end
  end

  defp supervisor_child_pids(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$initial_call") do
          {Supervisor, _, _} -> safe_supervisor_children(pid)
          {:supervisor, _, _} -> safe_supervisor_children(pid)
          _ -> []
        end

      _ ->
        []
    end
  end

  defp safe_supervisor_children(pid) do
    pid
    |> Supervisor.which_children()
    |> Enum.map(fn {_id, child_pid, _type, _modules} -> child_pid end)
    |> Enum.filter(&is_pid/1)
  rescue
    ArgumentError -> []
  end

  defp exceeded_limits(usage, limits) do
    []
    |> maybe_exceed_limit(:max_memory, usage.memory, limits)
    |> maybe_exceed_limit(:max_processes, usage.processes, limits)
    |> Enum.reverse()
  end

  defp maybe_exceed_limit(exceeded, key, value, limits) do
    case Map.get(limits, key) do
      limit when is_integer(limit) and limit >= 0 and value > limit ->
        [key | exceeded]

      _ ->
        exceeded
    end
  end

  defp split_server_opts(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_opts = Keyword.delete(opts, :server)
    {server, call_opts}
  end

  defp ensure_table(table_name, opts) do
    case :ets.whereis(table_name) do
      :undefined ->
        try do
          :ets.new(table_name, opts)
        catch
          :error, :badarg ->
            table_name
        end

      _ ->
        table_name
    end
  end
end
