defmodule Demo.SandboxRunner do
  @moduledoc "Sandbox lifecycle helpers for the demo."

  def sandbox_path do
    Path.expand("../../sandbox_app", __DIR__)
  end

  def create_sandbox(sandbox_id, sandbox_path \\ sandbox_path()) do
    Sandbox.create_sandbox(sandbox_id, DemoSandbox.Supervisor, sandbox_path: sandbox_path)
  end

  def hot_reload(sandbox_id) do
    Sandbox.hot_reload_source(sandbox_id, hot_reload_source())
  end

  def run_in_sandbox(sandbox_id) do
    with {:ok, worker_module} <- resolve_module(sandbox_id, DemoSandbox.Worker) do
      Sandbox.run(sandbox_id, fn -> worker_module.answer() end, timeout: 5_000)
    end
  end

  def induce_process_load(sandbox_id, count \\ 25)

  def induce_process_load(sandbox_id, count)
      when is_binary(sandbox_id) and is_integer(count) and count > 0 do
    with {:ok, supervisor_pid} <- sandbox_supervisor_pid(sandbox_id),
         {:ok, started} <-
           Sandbox.run(sandbox_id, fn ->
             Enum.reduce(1..count, 0, fn index, acc ->
               child_id = {:demo_load, index, System.unique_integer([:positive])}

               spec = %{
                 id: child_id,
                 start: {Task, :start_link, [fn -> Process.sleep(:infinity) end]},
                 restart: :temporary,
                 shutdown: 5_000
               }

               case Supervisor.start_child(supervisor_pid, spec) do
                 {:ok, _pid} -> acc + 1
                 {:error, {:already_started, _pid}} -> acc + 1
                 _ -> acc
               end
             end)
           end) do
      {:ok, started}
    end
  end

  def induce_process_load(_sandbox_id, _count) do
    {:error, :invalid_process_load}
  end

  def destroy_sandbox(sandbox_id) do
    Sandbox.destroy_sandbox(sandbox_id)
  end

  defp sandbox_supervisor_pid(sandbox_id) do
    case Sandbox.get_sandbox_info(sandbox_id) do
      {:ok, %{supervisor_pid: pid}} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :supervisor_not_running}

      {:ok, %{app_pid: pid}} when is_pid(pid) ->
        if Process.alive?(pid), do: {:ok, pid}, else: {:error, :supervisor_not_running}

      {:ok, _info} ->
        {:error, :supervisor_not_available}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_module(sandbox_id, module) do
    module_name = module_name_without_elixir(module)

    case Sandbox.ModuleTransformer.lookup_module_mapping(sandbox_id, module_name) do
      {:ok, mapped} ->
        {:ok, normalize_module_atom(mapped)}

      :not_found ->
        case Sandbox.Manager.get_hot_reload_context(sandbox_id) do
          {:ok, %{module_namespace_prefix: prefix}} when is_binary(prefix) ->
            mapped = :"#{prefix}_#{module_name}"
            {:ok, normalize_module_atom(mapped)}

          _ ->
            {:error, :module_mapping_not_found}
        end
    end
  end

  defp module_name_without_elixir(module) do
    module
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.to_atom()
  end

  defp normalize_module_atom(module) do
    module_str = Atom.to_string(module)

    if String.starts_with?(module_str, "Elixir.") do
      module
    else
      String.to_atom("Elixir." <> module_str)
    end
  end

  defp hot_reload_source do
    """
    defmodule DemoSandbox.Worker do
      use GenServer

      def start_link(_opts) do
        GenServer.start_link(__MODULE__, :ready, [])
      end

      def answer do
        42
      end

      @impl true
      def init(state) do
        {:ok, state}
      end
    end
    """
  end
end
