defmodule Sandbox.Application do
  @moduledoc """
  The Sandbox application module that starts the supervision tree and initializes ETS tables.

  This module is responsible for:
  - Starting the main supervision tree
  - Initializing ETS tables for sandbox registry
  - Setting up telemetry events
  - Configuring the sandbox system
  """

  use Application

  require Logger

  alias Sandbox.Config

  @doc false
  def start(_type, _args) do
    Logger.info("Starting Sandbox application...")

    # Initialize ETS tables for sandbox registry
    table_names = Config.table_names()
    service_names = Config.service_names()
    table_prefixes = Config.table_prefixes()
    persist_ets_on_start = Config.persist_ets_on_start?()

    :ok = init_ets_tables(table_names: table_names, persist_ets_on_start: persist_ets_on_start)

    # Emit telemetry event for application startup
    :telemetry.execute([:sandbox, :application, :start], %{}, %{})

    children = [
      # Core sandbox components
      {Sandbox.Manager,
       [
         name: service_names.manager,
         table_names: table_names,
         table_prefixes: table_prefixes,
         services: service_names
       ]},
      {Sandbox.ModuleVersionManager,
       [name: service_names.module_version_manager, table_name: table_names.module_versions]},

      # Process isolation infrastructure (Phase 2)
      {Sandbox.ProcessIsolator,
       [name: service_names.process_isolator, table_name: table_names.isolation_contexts]},

      # Resource monitoring and security
      {Sandbox.ResourceMonitor, [name: service_names.resource_monitor]},
      {Sandbox.SecurityController, [name: service_names.security_controller]},

      # File watching system
      {Sandbox.FileWatcher, [name: service_names.file_watcher]},

      # State preservation system
      {Sandbox.StatePreservation, [name: service_names.state_preservation]}
    ]

    opts = [strategy: :one_for_one, name: Sandbox.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Sandbox application started successfully")

        {:ok, pid,
         %{
           table_names: table_names,
           cleanup_ets_on_stop: Config.cleanup_ets_on_stop?()
         }}

      {:error, reason} ->
        Logger.error("Failed to start Sandbox application: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def stop(state) do
    Logger.info("Stopping Sandbox application...")

    # Cleanup ETS tables only if explicitly configured
    if Config.cleanup_ets_on_stop?(state) do
      cleanup_ets_tables(table_names: table_names_from_state(state))
    end

    # Emit telemetry event for application stop
    :telemetry.execute([:sandbox, :application, :stop], %{}, %{})

    :ok
  end

  @doc """
  Initializes ETS tables used by the sandbox system.

  Creates the following tables:
  - `:sandbox_registry` - Main registry for sandbox state and metadata
  - `:sandbox_modules` - Module version tracking and metadata
  - `:sandbox_resources` - Resource usage tracking
  - `:sandbox_security` - Security events and audit log

  This function is idempotent and safe to call multiple times.
  """
  def init_ets_tables(opts \\ []) do
    table_names = Config.table_names(opts)
    persist_ets_on_start = Config.persist_ets_on_start?(opts)

    tables = [
      {table_names.sandbox_registry,
       [
         :named_table,
         :public,
         :set,
         {:read_concurrency, true},
         {:write_concurrency, true}
       ]},
      {table_names.sandbox_modules,
       [
         :named_table,
         :public,
         :bag,
         {:read_concurrency, true},
         {:write_concurrency, true}
       ]},
      {table_names.sandbox_resources,
       [
         :named_table,
         :public,
         :set,
         {:read_concurrency, true},
         {:write_concurrency, true}
       ]},
      {table_names.sandbox_security,
       [
         :named_table,
         :public,
         :ordered_set,
         {:read_concurrency, true},
         {:write_concurrency, true}
       ]}
    ]

    Enum.each(tables, fn {name, table_opts} ->
      ensure_table(name, table_opts, persist_ets_on_start)
    end)

    Logger.debug("ETS tables initialized successfully")
    :ok
  end

  @doc """
  Cleans up ETS tables on application shutdown.
  """
  def cleanup_ets_tables(opts \\ []) do
    table_names = Config.table_names(opts)

    tables = [
      table_names.sandbox_registry,
      table_names.sandbox_modules,
      table_names.sandbox_resources,
      table_names.sandbox_security
    ]

    Enum.each(tables, fn table ->
      if :ets.whereis(table) != :undefined do
        :ets.delete(table)
        Logger.debug("Cleaned up ETS table: #{table}")
      end
    end)

    :ok
  end

  @doc """
  Gets information about the ETS tables used by the sandbox system.

  Returns a map with table names as keys and table info as values.
  """
  def get_ets_info(opts \\ []) do
    table_names = Config.table_names(opts)

    tables = [
      table_names.sandbox_registry,
      table_names.sandbox_modules,
      table_names.sandbox_resources,
      table_names.sandbox_security
    ]

    Enum.into(tables, %{}, fn table -> {table, get_table_info(table)} end)
  end

  defp get_table_info(table) do
    if :ets.whereis(table) == :undefined do
      :not_found
    else
      fetch_table_info(table)
    end
  end

  defp fetch_table_info(table) do
    # The table can be deleted between the whereis/1 and info/1 calls.
    # We must handle the :undefined case for :ets.info/1.
    case :ets.info(table) do
      info when is_list(info) ->
        %{
          size: info[:size],
          memory: info[:memory],
          type: info[:type],
          protection: info[:protection]
        }

      :undefined ->
        # The table was deleted after our check, which is fine.
        :not_found
    end
  end

  defp table_names_from_state(%{table_names: table_names}), do: table_names
  defp table_names_from_state(_state), do: Config.table_names()

  defp create_ets_table(name, opts) do
    :ets.new(name, opts)
    Logger.debug("Created ETS table: #{name}")
  rescue
    ArgumentError ->
      Logger.debug("ETS table #{name} was created concurrently by another process")
  end

  defp reset_ets_table(name, opts) do
    delete_ets_table(name)
    create_ets_table(name, opts)
  end

  defp ensure_table(name, table_opts, persist_ets_on_start) do
    case :ets.whereis(name) do
      :undefined ->
        create_ets_table(name, table_opts)

      _existing_ref when persist_ets_on_start ->
        Logger.debug("ETS table already exists: #{name}")

      _existing_ref ->
        reset_ets_table(name, table_opts)
    end
  end

  defp delete_ets_table(name) do
    :ets.delete(name)
  rescue
    ArgumentError ->
      :ok
  end
end
