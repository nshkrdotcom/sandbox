defmodule Sandbox.SecurityController do
  @moduledoc """
  Provides security controls and code analysis for safe execution.
  """

  use GenServer

  require Logger

  alias Sandbox.Config

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register_sandbox(sandbox_id, profile \\ :medium, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:register_sandbox, sandbox_id, profile, call_opts})
  end

  def authorize_operation(sandbox_id, operation, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:authorize_operation, sandbox_id, operation, call_opts})
  end

  def audit_event(sandbox_id, event, metadata \\ %{}, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:audit_event, sandbox_id, event, metadata, call_opts})
  end

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name) || Config.table_name(:sandbox_security, opts)

    ensure_table(table_name, [
      :named_table,
      :ordered_set,
      :public,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    Logger.debug("SecurityController starting with opts: #{inspect(opts)}")
    {:ok, %{profiles: %{}, table_name: table_name}}
  end

  @impl true
  def handle_call({:register_sandbox, sandbox_id, profile, _opts}, _from, state) do
    case normalize_profile(profile) do
      {:ok, normalized} ->
        updated_state = %{
          state
          | profiles: Map.put(state.profiles, sandbox_id, normalized)
        }

        {:reply, :ok, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:authorize_operation, sandbox_id, operation, opts}, _from, state) do
    profile =
      case Keyword.fetch(opts, :security_profile) do
        {:ok, override} ->
          normalize_profile(override)

        :error ->
          {:ok, Map.get(state.profiles, sandbox_id, default_profile())}
      end

    case profile do
      {:ok, resolved_profile} ->
        if allowed_operation?(resolved_profile, operation) do
          {:reply, :ok, state}
        else
          {:reply, {:error, :operation_not_allowed}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:audit_event, sandbox_id, event, metadata, _opts}, _from, state) do
    entry_id = System.unique_integer([:positive])

    entry = %{
      event: event,
      metadata: metadata,
      recorded_at: DateTime.utc_now()
    }

    :ets.insert(state.table_name, {{sandbox_id, entry_id}, entry})

    {:reply, :ok, state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_info, state) do
    {:noreply, state}
  end

  defp normalize_profile(profile) when is_atom(profile) do
    case profile do
      :high -> {:ok, high_profile()}
      :medium -> {:ok, default_profile()}
      :low -> {:ok, low_profile()}
      _ -> {:error, :invalid_profile}
    end
  end

  defp normalize_profile(profile) when is_map(profile) do
    {:ok, Map.merge(default_profile(), profile)}
  end

  defp normalize_profile(_), do: {:error, :invalid_profile}

  defp allowed_operation?(profile, operation) do
    allowed = Map.get(profile, :allowed_operations, [])
    restricted = Map.get(profile, :restricted_modules, [])

    case operation do
      {:module, module} ->
        if Enum.member?(restricted, module) do
          false
        else
          :all in allowed or operation in allowed
        end

      _ ->
        :all in allowed or operation in allowed
    end
  end

  defp default_profile do
    %{
      isolation_level: :medium,
      allowed_operations: [:basic_otp, :math, :string, :processes],
      restricted_modules: [:os, :port, :node],
      audit_level: :basic
    }
  end

  defp high_profile do
    %{
      isolation_level: :high,
      allowed_operations: [:basic_otp, :math, :string],
      restricted_modules: [:file, :os, :code, :system, :port, :node],
      audit_level: :full
    }
  end

  defp low_profile do
    %{
      isolation_level: :low,
      allowed_operations: [:all],
      restricted_modules: [],
      audit_level: :basic
    }
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
