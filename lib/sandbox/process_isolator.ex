defmodule Sandbox.ProcessIsolator do
  @moduledoc """
  Process-based isolation infrastructure for sandboxes.

  This module implements Phase 2 of the optimal module isolation architecture,
  providing process-level isolation where each sandbox runs in its own
  isolated process context with separate supervision trees.

  Key features:
  - Process isolation with separate supervision trees
  - Memory isolation with individual heap spaces
  - Error isolation preventing cross-sandbox crashes
  - Resource monitoring and limits per sandbox
  - Safe inter-sandbox communication channels
  """

  use GenServer
  require Logger

  alias Sandbox.Config

  @doc """
  Starts the process isolator.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates an isolated process context for a sandbox.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `supervisor_module`: The supervisor module to run in isolation
  - `opts`: Options for process isolation
    - `:resource_limits` - Memory, process, and time limits
    - `:isolation_level` - :strict, :medium, :relaxed (default: :medium)
    - `:communication_mode` - :none, :message_passing, :shared_ets (default: :message_passing)

  ## Returns
  - `{:ok, isolation_context}` - Success with isolation context
  - `{:error, reason}` - Isolation setup failed
  """
  def create_isolated_context(sandbox_id, supervisor_module, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)

    GenServer.call(
      server,
      {:create_isolated_context, sandbox_id, supervisor_module, call_opts},
      30_000
    )
  end

  @doc """
  Destroys an isolated process context.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox

  ## Returns
  - `:ok` - Context destroyed successfully
  - `{:error, reason}` - Destruction failed
  """
  def destroy_isolated_context(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:destroy_isolated_context, sandbox_id}, 15_000)
  end

  @doc """
  Gets information about an isolated context.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox

  ## Returns
  - `{:ok, context_info}` - Context information
  - `{:error, :not_found}` - Context doesn't exist
  """
  def get_context_info(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_context_info, sandbox_id})
  end

  @doc """
  Lists all active isolated contexts.

  ## Returns
  - List of context information maps
  """
  def list_contexts(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_contexts)
  end

  @doc """
  Sends a message to a sandbox in an isolated context.

  ## Parameters
  - `sandbox_id`: Target sandbox identifier
  - `message`: Message to send
  - `opts`: Communication options

  ## Returns
  - `:ok` - Message sent successfully
  - `{:error, reason}` - Send failed
  """
  def send_message_to_sandbox(sandbox_id, message, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:send_message, sandbox_id, message, call_opts})
  end

  # GenServer implementation

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name) || Config.table_name(:isolation_contexts, opts)

    ensure_table(table_name, [
      :named_table,
      :set,
      :public,
      {:read_concurrency, true}
    ])

    state = %{
      contexts: %{},
      monitors: %{},
      resource_tracker: nil,
      table_name: table_name
    }

    Logger.info("Process isolator started successfully")
    {:ok, state}
  end

  @impl true
  def handle_call({:create_isolated_context, sandbox_id, supervisor_module, opts}, _from, state) do
    case create_isolation_context(sandbox_id, supervisor_module, opts, state) do
      {:ok, context, updated_state} ->
        Logger.info("Created isolated context for sandbox #{sandbox_id}",
          isolation_level: context.isolation_level,
          resource_limits: context.resource_limits
        )

        {:reply, {:ok, context}, updated_state}

      {:error, reason} ->
        Logger.error("Failed to create isolated context for sandbox #{sandbox_id}",
          reason: inspect(reason)
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:destroy_isolated_context, sandbox_id}, _from, state) do
    case destroy_isolation_context(sandbox_id, state) do
      {:ok, updated_state} ->
        Logger.info("Destroyed isolated context for sandbox #{sandbox_id}")
        {:reply, :ok, updated_state}

      {:error, reason} ->
        Logger.error("Failed to destroy isolated context for sandbox #{sandbox_id}",
          reason: inspect(reason)
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:get_context_info, sandbox_id}, _from, state) do
    case Map.get(state.contexts, sandbox_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      context ->
        # Get real-time resource usage
        updated_context = update_context_metrics(context)
        {:reply, {:ok, updated_context}, state}
    end
  end

  @impl true
  def handle_call(:list_contexts, _from, state) do
    contexts =
      state.contexts
      |> Enum.map(fn {_id, context} -> update_context_metrics(context) end)

    {:reply, contexts, state}
  end

  @impl true
  def handle_call({:send_message, sandbox_id, message, opts}, _from, state) do
    case send_isolated_message(sandbox_id, message, opts, state) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.get(state.monitors, monitor_ref) do
      nil ->
        {:noreply, state}

      sandbox_id ->
        Logger.warning("Isolated context process died for sandbox #{sandbox_id}",
          reason: inspect(reason)
        )

        # Clean up the context
        updated_state = cleanup_crashed_context(sandbox_id, monitor_ref, state)
        {:noreply, updated_state}
    end
  end

  # Private implementation functions

  defp create_isolation_context(sandbox_id, supervisor_module, opts, state) do
    # Check if context already exists
    if Map.has_key?(state.contexts, sandbox_id) do
      {:error, {:already_exists, sandbox_id}}
    else
      isolation_level = Keyword.get(opts, :isolation_level, :medium)
      communication_mode = Keyword.get(opts, :communication_mode, :message_passing)
      resource_limits = Keyword.get(opts, :resource_limits, default_resource_limits())

      # Create isolated process
      case spawn_isolated_process(sandbox_id, supervisor_module, opts) do
        {:ok, isolated_pid, isolation_data} ->
          # Set up monitoring
          monitor_ref = Process.monitor(isolated_pid)

          # Create context
          context = %{
            sandbox_id: sandbox_id,
            supervisor_module: supervisor_module,
            isolated_pid: isolated_pid,
            isolation_level: isolation_level,
            communication_mode: communication_mode,
            resource_limits: resource_limits,
            isolation_data: isolation_data,
            created_at: DateTime.utc_now(),
            status: :running,
            resource_usage: %{
              memory: 0,
              processes: 0,
              uptime: 0
            }
          }

          # Store in ETS for fast lookup
          :ets.insert(state.table_name, {sandbox_id, context})

          # Update state
          updated_state = %{
            state
            | contexts: Map.put(state.contexts, sandbox_id, context),
              monitors: Map.put(state.monitors, monitor_ref, sandbox_id)
          }

          {:ok, context, updated_state}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp destroy_isolation_context(sandbox_id, state) do
    case Map.get(state.contexts, sandbox_id) do
      nil ->
        {:error, :not_found}

      context ->
        # Terminate isolated process gracefully
        terminate_isolated_process(context)

        # Clean up monitoring
        monitor_ref = find_monitor_ref(sandbox_id, state.monitors)

        if monitor_ref do
          Process.demonitor(monitor_ref, [:flush])
        end

        # Remove from ETS
        :ets.delete(state.table_name, sandbox_id)

        # Update state
        updated_state = %{
          state
          | contexts: Map.delete(state.contexts, sandbox_id),
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        {:ok, updated_state}
    end
  end

  defp spawn_isolated_process(sandbox_id, supervisor_module, opts) do
    isolation_level = Keyword.get(opts, :isolation_level, :medium)
    resource_limits = Keyword.get(opts, :resource_limits, default_resource_limits())

    # Prepare isolation configuration
    isolation_config = %{
      sandbox_id: sandbox_id,
      supervisor_module: supervisor_module,
      isolation_level: isolation_level,
      resource_limits: resource_limits,
      # Phase 2 includes Phase 1 transformations
      module_transformer: true
    }

    try do
      # Spawn the isolated process with appropriate flags
      spawn_opts = build_spawn_options(isolation_level, resource_limits)

      isolated_pid =
        :proc_lib.spawn_opt(
          fn ->
            isolated_process_main(isolation_config)
          end,
          spawn_opts
        )

      # Set up initial resource monitoring
      isolation_data = %{
        spawn_opts: spawn_opts,
        start_time: System.monotonic_time(:millisecond)
      }

      {:ok, isolated_pid, isolation_data}
    rescue
      error ->
        {:error, {:spawn_failed, error}}
    end
  end

  defp build_spawn_options(isolation_level, resource_limits) do
    base_opts = []

    # Add isolation-specific options
    case isolation_level do
      :strict ->
        # Maximum isolation
        max_heap = Map.get(resource_limits, :max_memory, 64 * 1024 * 1024)

        base_opts ++
          [
            {:max_heap_size, max_heap},
            {:message_queue_data, :off_heap},
            {:priority, :low}
          ]

      :medium ->
        # Balanced isolation
        max_heap = Map.get(resource_limits, :max_memory, 128 * 1024 * 1024)

        base_opts ++
          [
            {:max_heap_size, max_heap},
            {:message_queue_data, :on_heap}
          ]

      :relaxed ->
        # Minimal isolation
        base_opts
    end
  end

  @dialyzer {:nowarn_function, isolated_process_main: 1}
  defp isolated_process_main(config) do
    %{
      sandbox_id: sandbox_id,
      supervisor_module: supervisor_module,
      isolation_level: isolation_level,
      resource_limits: resource_limits
    } = config

    # Set process dictionary for identification
    Process.put(:sandbox_id, sandbox_id)
    Process.put(:isolation_level, isolation_level)
    Process.put(:start_time, System.monotonic_time(:millisecond))

    Logger.debug("Starting isolated process for sandbox #{sandbox_id}",
      isolation_level: isolation_level,
      supervisor_module: supervisor_module
    )

    try do
      # Set up resource monitoring within the isolated process
      setup_internal_resource_monitoring(resource_limits)

      # Initialize the supervisor module in the isolated context
      case supervisor_module.start_link([]) do
        {:ok, supervisor_pid} ->
          # Keep the process alive and monitor the supervisor
          ref = Process.monitor(supervisor_pid)

          isolated_process_loop(sandbox_id, supervisor_pid, ref)

        {:error, reason} ->
          Logger.error("Failed to start supervisor in isolated process",
            sandbox_id: sandbox_id,
            reason: inspect(reason)
          )

          exit({:supervisor_start_failed, reason})
      end
    rescue
      error ->
        Logger.error("Error in isolated process for sandbox #{sandbox_id}",
          error: inspect(error)
        )

        exit({:isolated_process_error, error})
    end
  end

  defp isolated_process_loop(sandbox_id, supervisor_pid, monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, ^supervisor_pid, reason} ->
        Logger.warning("Supervisor died in isolated process for sandbox #{sandbox_id}",
          reason: inspect(reason)
        )

        exit({:supervisor_died, reason})

      {:isolator_message, message} ->
        # Handle messages from the isolator
        handle_isolated_message(sandbox_id, message)
        isolated_process_loop(sandbox_id, supervisor_pid, monitor_ref)

      {:resource_check} ->
        # Perform resource usage check
        perform_resource_check(sandbox_id)
        isolated_process_loop(sandbox_id, supervisor_pid, monitor_ref)

      other ->
        Logger.debug("Isolated process received unknown message",
          sandbox_id: sandbox_id,
          message: inspect(other)
        )

        isolated_process_loop(sandbox_id, supervisor_pid, monitor_ref)
    end
  end

  defp setup_internal_resource_monitoring(resource_limits) do
    # Set up memory limit monitoring
    if max_memory = Map.get(resource_limits, :max_memory) do
      # Note: max_heap_size is already set at spawn, this is for additional monitoring
      Process.flag(:max_heap_size, max_memory)
    end

    # Set up process limit monitoring
    if max_processes = Map.get(resource_limits, :max_processes) do
      # This would require more complex implementation to actually enforce
      Process.put(:max_processes, max_processes)
    end

    :ok
  end

  defp handle_isolated_message(sandbox_id, message) do
    Logger.debug("Handling message in isolated process",
      sandbox_id: sandbox_id,
      message: inspect(message)
    )

    # Process the message based on its type
    case message do
      {:ping} ->
        # Health check
        send(self(), {:pong, sandbox_id})

      {:resource_report} ->
        # Send back resource usage
        usage = get_isolated_resource_usage()
        send(self(), {:resource_usage, sandbox_id, usage})

      {:shutdown} ->
        # Graceful shutdown request
        exit(:shutdown)

      _ ->
        Logger.warning("Unknown message type in isolated process",
          sandbox_id: sandbox_id,
          message: inspect(message)
        )
    end
  end

  defp perform_resource_check(sandbox_id) do
    usage = get_isolated_resource_usage()

    Logger.debug("Resource check for isolated sandbox",
      sandbox_id: sandbox_id,
      memory: usage.memory,
      processes: usage.processes
    )

    # Could implement resource limit enforcement here
    usage
  end

  defp get_isolated_resource_usage do
    process_info = Process.info(self(), [:memory, :message_queue_len, :total_heap_size])

    %{
      memory: process_info[:total_heap_size] || 0,
      # This process plus any children
      processes: 1,
      message_queue: process_info[:message_queue_len] || 0,
      uptime: System.monotonic_time(:millisecond) - (Process.get(:start_time) || 0)
    }
  end

  defp terminate_isolated_process(context) do
    if Process.alive?(context.isolated_pid) do
      # Send graceful shutdown message first
      send(context.isolated_pid, {:isolator_message, {:shutdown}})

      # Wait efficiently for graceful shutdown with shorter timeout
      ref = Process.monitor(context.isolated_pid)

      receive do
        {:DOWN, ^ref, :process, _, _} ->
          # Process shut down gracefully
          Process.demonitor(ref, [:flush])
      after
        # Much shorter timeout: 100ms instead of 1000ms
        100 ->
          Process.demonitor(ref, [:flush])

          # Force kill if still alive
          if Process.alive?(context.isolated_pid) do
            Process.exit(context.isolated_pid, :kill)
          end
      end
    end
  end

  defp send_isolated_message(sandbox_id, message, _opts, state) do
    case Map.get(state.contexts, sandbox_id) do
      nil ->
        {:error, :not_found}

      context ->
        if Process.alive?(context.isolated_pid) do
          send(context.isolated_pid, {:isolator_message, message})
          :ok
        else
          {:error, :process_dead}
        end
    end
  end

  defp update_context_metrics(context) do
    if Process.alive?(context.isolated_pid) do
      # Get current resource usage
      case Process.info(context.isolated_pid, [:memory, :message_queue_len, :total_heap_size]) do
        nil ->
          # Process is dead
          %{context | status: :dead}

        process_info ->
          uptime = DateTime.diff(DateTime.utc_now(), context.created_at, :millisecond)

          updated_usage = %{
            memory: process_info[:total_heap_size] || 0,
            processes: 1,
            uptime: uptime,
            message_queue: process_info[:message_queue_len] || 0
          }

          %{context | resource_usage: updated_usage}
      end
    else
      %{context | status: :dead}
    end
  end

  defp cleanup_crashed_context(sandbox_id, monitor_ref, state) do
    # Remove from ETS
    :ets.delete(state.table_name, sandbox_id)

    # Update state
    %{
      state
      | contexts: Map.delete(state.contexts, sandbox_id),
        monitors: Map.delete(state.monitors, monitor_ref)
    }
  end

  defp find_monitor_ref(sandbox_id, monitors) do
    Enum.find_value(monitors, fn {ref, id} ->
      if id == sandbox_id, do: ref
    end)
  end

  defp default_resource_limits do
    %{
      # 128MB
      max_memory: 128 * 1024 * 1024,
      max_processes: 1000,
      # 5 minutes
      max_execution_time: 300_000
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
