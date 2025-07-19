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

  @doc false
  def start(_type, _args) do
    Logger.info("Starting Sandbox application...")

    # Initialize ETS tables for sandbox registry
    :ok = init_ets_tables()

    # Emit telemetry event for application startup
    :telemetry.execute([:sandbox, :application, :start], %{}, %{})

    children = [
      # Core sandbox components
      Sandbox.Manager,
      Sandbox.ModuleVersionManager,

      # Resource monitoring and security
      {Sandbox.ResourceMonitor, []},
      {Sandbox.SecurityController, []},

      # File watching system
      {Sandbox.FileWatcher, []},

      # State preservation system
      {Sandbox.StatePreservation, []}
    ]

    opts = [strategy: :one_for_one, name: Sandbox.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("Sandbox application started successfully")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start Sandbox application: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  def stop(_state) do
    Logger.info("Stopping Sandbox application...")

    # Cleanup ETS tables
    cleanup_ets_tables()

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
  """
  def init_ets_tables do
    # Main sandbox registry - stores sandbox state and metadata
    :ets.new(:sandbox_registry, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    # Module version tracking
    :ets.new(:sandbox_modules, [
      :named_table,
      :public,
      # Multiple versions per module
      :bag,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    # Resource usage tracking
    :ets.new(:sandbox_resources, [
      :named_table,
      :public,
      :set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    # Security events and audit log
    :ets.new(:sandbox_security, [
      :named_table,
      :public,
      # Ordered by timestamp
      :ordered_set,
      {:read_concurrency, true},
      {:write_concurrency, true}
    ])

    Logger.debug("ETS tables initialized successfully")
    :ok
  end

  @doc """
  Cleans up ETS tables on application shutdown.
  """
  def cleanup_ets_tables do
    tables = [:sandbox_registry, :sandbox_modules, :sandbox_resources, :sandbox_security]

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
  def get_ets_info do
    tables = [:sandbox_registry, :sandbox_modules, :sandbox_resources, :sandbox_security]

    Enum.into(tables, %{}, fn table ->
      if :ets.whereis(table) != :undefined do
        info = :ets.info(table)

        {table,
         %{
           size: info[:size],
           memory: info[:memory],
           type: info[:type],
           protection: info[:protection]
         }}
      else
        {table, :not_found}
      end
    end)
  end
end
