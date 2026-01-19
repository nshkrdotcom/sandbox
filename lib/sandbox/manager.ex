defmodule Sandbox.Manager do
  @moduledoc """
  Enhanced sandbox manager with comprehensive process monitoring and lifecycle management.

  This manager provides complete sandbox lifecycle management with:
  - Comprehensive process monitoring with proper DOWN message handling
  - Sandbox state tracking with status transitions
  - Cleanup mechanisms for crashed sandboxes with resource recovery
  - Sandbox registry management with ETS operations and conflict resolution
  - Enhanced error handling and recovery strategies
  """

  use GenServer
  require Logger

  alias Sandbox.Config
  alias Sandbox.IsolatedCompiler
  alias Sandbox.Models.SandboxState
  alias Sandbox.ModuleTransformer
  alias Sandbox.ModuleVersionManager
  alias Sandbox.ProcessIsolator
  alias Sandbox.VirtualCodeTable

  @default_source_exclude_dirs [
    "_build",
    "deps",
    "test",
    "lib/mix"
  ]

  # Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Creates a new sandbox with comprehensive validation and resource setup.

  ## Arguments

    * `sandbox_id` - Unique identifier for the sandbox
    * `module_or_app` - Either a supervisor module or application name
    * `opts` - Options for sandbox creation

  ## Options

    * `:supervisor_module` - Supervisor module to use (if app name provided)
    * `:sandbox_path` - Path to sandbox code directory
    * `:compile_timeout` - Compilation timeout in milliseconds (default: 30000)
    * `:resource_limits` - Resource limits map (default: medium profile)
    * `:security_profile` - Security profile (:high, :medium, :low, default: :medium)
    * `:isolation_mode` - Isolation mode (:process, :module, :hybrid, :ets, default: :hybrid)
    * `:isolation_level` - For process isolation (:strict, :medium, :relaxed, default: :medium)
    * `:communication_mode` - Inter-sandbox communication (:none, :message_passing, :shared_ets, default: :message_passing)
    * `:auto_reload` - Enable automatic file watching (default: false)
    * `:state_migration_handler` - Custom state migration function
    * `:source_exclude_dirs` - Directories to ignore when transforming/compiling source
    * `:protocol_consolidation` - :reconsolidate or :none (default: :reconsolidate)

  ## Examples

      iex> create_sandbox("my-sandbox", MyApp.Supervisor)
      {:ok, %{id: "my-sandbox", status: :running, ...}}
      
      iex> create_sandbox("test-sandbox", :my_app, 
      ...>   supervisor_module: MyApp.Supervisor,
      ...>   resource_limits: %{max_memory: 64 * 1024 * 1024}
      ...> )
      {:ok, %{id: "test-sandbox", ...}}
  """
  def create_sandbox(sandbox_id, module_or_app, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:create_sandbox, sandbox_id, module_or_app, call_opts}, 30_000)
  end

  @doc """
  Destroys a sandbox with complete cleanup including ETS and process termination.

  Performs comprehensive cleanup including:
  - Process termination with graceful shutdown
  - ETS table cleanup
  - Module version cleanup
  - Temporary file cleanup
  - Resource monitoring cleanup

  ## Examples

      iex> destroy_sandbox("my-sandbox")
      :ok
  """
  def destroy_sandbox(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:destroy_sandbox, sandbox_id}, 15_000)
  end

  @doc """
  Restarts a sandbox with state preservation and configuration retention.

  Attempts to preserve as much state as possible during restart while
  maintaining the same configuration and incrementing restart count.

  ## Examples

      iex> restart_sandbox("my-sandbox")
      {:ok, %{id: "my-sandbox", restart_count: 1, ...}}
  """
  def restart_sandbox(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:restart_sandbox, sandbox_id}, 30_000)
  end

  @doc """
  Hot-reloads a sandbox with new code.
  """
  def hot_reload_sandbox(sandbox_id, new_beam_data, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)

    GenServer.call(server, {:hot_reload_sandbox, sandbox_id, new_beam_data, call_opts}, 30_000)
  end

  @doc """
  Gets detailed status reporting for a specific sandbox.

  Returns comprehensive information including:
  - Current status and process information
  - Resource usage statistics
  - Configuration details
  - Security profile information
  - Restart count and timestamps

  ## Examples

      iex> get_sandbox_info("my-sandbox")
      {:ok, %{
        id: "my-sandbox",
        status: :running,
        resource_usage: %{current_memory: 45_000_000, ...},
        ...
      }}
  """
  def get_sandbox_info(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_sandbox_info, sandbox_id})
  end

  @doc """
  Lists all sandboxes with detailed status reporting.

  Returns a list of all sandbox information including status,
  resource usage, and configuration details.

  ## Examples

      iex> list_sandboxes()
      [
        %{id: "sandbox-1", status: :running, ...},
        %{id: "sandbox-2", status: :stopped, ...}
      ]
  """
  def list_sandboxes(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :list_sandboxes)
  end

  @doc """
  Gets the main process PID for a sandbox.
  """
  def get_sandbox_pid(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_sandbox_pid, sandbox_id})
  end

  def get_run_context(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_run_context, sandbox_id})
  end

  def get_hot_reload_context(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get_hot_reload_context, sandbox_id})
  end

  def resource_usage(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:resource_usage, sandbox_id})
  end

  @doc """
  Synchronizes state (useful for testing).
  """
  def sync(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, :sync)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    table_names = Config.table_names(opts)
    services = Config.service_names(opts)
    table_prefixes = Config.table_prefixes(opts)

    sandboxes_table = table_names.sandboxes
    monitors_table = table_names.sandbox_monitors

    ensure_table(sandboxes_table, [:named_table, :set, :public, {:read_concurrency, true}])
    ensure_table(monitors_table, [:named_table, :set, :public])

    state = %{
      sandboxes: %{},
      monitors: %{},
      cleanup_tasks: %{},
      next_cleanup_id: 1,
      tables: %{sandboxes: sandboxes_table, sandbox_monitors: monitors_table},
      services: services,
      table_prefixes: table_prefixes
    }

    Logger.info("Enhanced Sandbox.Manager started with comprehensive monitoring")
    {:ok, state}
  end

  @impl true
  def handle_call({:create_sandbox, sandbox_id, module_or_app, opts}, _from, state) do
    # Check for existing sandbox with conflict resolution
    case resolve_sandbox_conflict(sandbox_id, state) do
      :conflict ->
        existing_info = get_existing_sandbox_info(sandbox_id, state)
        {:reply, {:error, {:already_exists, existing_info}}, state}

      :proceed ->
        # Validate configuration with comprehensive error messages
        case validate_sandbox_config(sandbox_id, module_or_app, opts) do
          {:ok, validated_config} ->
            create_sandbox_with_monitoring(sandbox_id, validated_config, state)

          {:error, validation_errors} ->
            Logger.warning("Sandbox creation failed validation",
              sandbox_id: sandbox_id,
              errors: validation_errors
            )

            {:reply, {:error, {:validation_failed, validation_errors}}, state}
        end
    end
  end

  @impl true
  def handle_call({:destroy_sandbox, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, monitor_ref} ->
        # Update status to stopping
        stopping_state = SandboxState.update_status(sandbox_state, :stopping)
        :ets.insert(state.tables.sandboxes, {sandbox_id, SandboxState.to_info(stopping_state)})

        # Perform comprehensive cleanup
        cleanup_result = perform_comprehensive_cleanup(sandbox_state, monitor_ref, state)

        case cleanup_result do
          {:ok, updated_state} ->
            Logger.info("Successfully destroyed sandbox with complete cleanup",
              sandbox_id: sandbox_id
            )

            {:reply, :ok, updated_state}

          {:error, reason, updated_state} ->
            Logger.error("Sandbox destruction completed with errors",
              sandbox_id: sandbox_id,
              errors: reason
            )

            {:reply, {:error, reason}, updated_state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:restart_sandbox, sandbox_id}, _from, state) do
    Logger.debug("Restart sandbox request received", sandbox_id: sandbox_id)

    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, monitor_ref} ->
        Logger.debug("Found sandbox for restart",
          sandbox_id: sandbox_id,
          current_status: sandbox_state.status
        )

        # Update status to stopping for restart
        stopping_state = SandboxState.update_status(sandbox_state, :stopping)
        :ets.insert(state.tables.sandboxes, {sandbox_id, SandboxState.to_info(stopping_state)})

        # Perform graceful shutdown with state preservation attempt
        case perform_graceful_restart(sandbox_state, monitor_ref, state) do
          {:ok, new_sandbox_state, _new_monitor_ref, updated_state} ->
            Logger.info("Successfully restarted sandbox with state preservation",
              sandbox_id: sandbox_id,
              restart_count: new_sandbox_state.restart_count
            )

            {:reply, {:ok, SandboxState.to_info(new_sandbox_state)}, updated_state}

          {:error, reason, updated_state} ->
            Logger.error("Sandbox restart failed",
              sandbox_id: sandbox_id,
              reason: inspect(reason)
            )

            {:reply, {:error, reason}, updated_state}
        end

      nil ->
        Logger.warning("Sandbox not found for restart", sandbox_id: sandbox_id)
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:hot_reload_sandbox, sandbox_id, new_beam_data, _opts}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {_sandbox_info, _ref} ->
        # Extract module from beam data
        module = extract_module_from_beam(new_beam_data)

        # Perform hot reload
        result =
          ModuleVersionManager.hot_swap_module(sandbox_id, module, new_beam_data,
            server: state.services.module_version_manager
          )

        case result do
          {:ok, :hot_swapped} ->
            Logger.info("Hot-reloaded sandbox #{sandbox_id}")
            {:reply, {:ok, :hot_reloaded}, state}

          {:ok, :no_change} ->
            {:reply, {:ok, :no_change}, state}

          {:error, reason} ->
            {:reply, {:error, {:hot_reload_failed, reason}}, state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_sandbox_info, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, _monitor_ref} ->
        # Get real-time resource usage if possible
        updated_info = get_detailed_sandbox_info(sandbox_state)
        {:reply, {:ok, updated_info}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_sandbox_pid, sandbox_id}, _from, state) do
    case :ets.lookup(state.tables.sandboxes, sandbox_id) do
      [{^sandbox_id, sandbox_info}] ->
        {:reply, {:ok, sandbox_info.app_pid}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_run_context, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, monitor_ref} ->
        case ensure_run_supervisor(sandbox_state) do
          {:ok, updated_sandbox_state, run_supervisor_pid} ->
            updated_state = %{
              state
              | sandboxes:
                  Map.put(state.sandboxes, sandbox_id, {updated_sandbox_state, monitor_ref})
            }

            context = %{
              sandbox_id: sandbox_id,
              run_supervisor_pid: run_supervisor_pid,
              resource_limits: Map.get(updated_sandbox_state.config, :resource_limits, %{})
            }

            {:reply, {:ok, context}, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_hot_reload_context, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, _monitor_ref} ->
        context = %{
          sandbox_id: sandbox_state.id,
          module_namespace_prefix: sandbox_state.module_namespace_prefix,
          services: state.services,
          table_prefixes: state.table_prefixes
        }

        {:reply, {:ok, context}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:resource_usage, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, _monitor_ref} ->
        {:reply, {:ok, sandbox_resource_usage(sandbox_state)}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sandboxes, _from, state) do
    sandbox_list =
      state.sandboxes
      |> Enum.map(fn {_sandbox_id, {sandbox_state, _monitor_ref}} ->
        get_detailed_sandbox_info(sandbox_state)
      end)
      |> Enum.sort_by(& &1.created_at, DateTime)

    {:reply, sandbox_list, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    Logger.info("Sandbox.Manager received DOWN message",
      pid: inspect(pid),
      reason: inspect(reason),
      ref: inspect(ref)
    )

    case Map.get(state.monitors, ref) do
      sandbox_id when is_binary(sandbox_id) ->
        handle_sandbox_crash(sandbox_id, ref, pid, reason, state)

      nil ->
        Logger.warning("Received DOWN message for unknown monitor reference",
          ref: inspect(ref),
          pid: inspect(pid)
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Sandbox.Manager received unexpected message", message: inspect(msg))
    {:noreply, state}
  end

  # Private Functions

  defp resolve_sandbox_conflict(sandbox_id, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      nil -> :proceed
      {%SandboxState{status: :stopped}, _} -> :proceed
      {%SandboxState{status: :error}, _} -> :proceed
      _ -> :conflict
    end
  end

  defp get_existing_sandbox_info(sandbox_id, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, _ref} -> SandboxState.to_info(sandbox_state)
      nil -> nil
    end
  end

  defp validate_sandbox_config(sandbox_id, module_or_app, opts) do
    with {:ok, {app_name, supervisor_module}} <-
           parse_and_validate_module_or_app(module_or_app, opts),
         {:ok, sandbox_path} <- validate_sandbox_path(opts),
         {:ok, resource_limits} <- validate_resource_limits(opts),
         {:ok, security_profile} <- validate_security_profile(opts) do
      config = %{
        sandbox_path: sandbox_path,
        compile_timeout: Keyword.get(opts, :compile_timeout, 30_000),
        resource_limits: resource_limits,
        auto_reload: Keyword.get(opts, :auto_reload, false),
        state_migration_handler: Keyword.get(opts, :state_migration_handler),
        security_profile: security_profile
      }

      {:ok, {sandbox_id, app_name, supervisor_module, config}}
    else
      {:error, reason} -> {:error, [reason]}
    end
  end

  defp parse_and_validate_module_or_app(module_or_app, opts) do
    case parse_module_or_app(module_or_app, opts) do
      {_app_name, nil} ->
        {:error,
         {:missing_supervisor_module, "supervisor_module option required when using app name"}}

      {app_name, supervisor_module} when is_atom(supervisor_module) ->
        if Code.ensure_loaded?(supervisor_module) do
          {:ok, {app_name, supervisor_module}}
        else
          {:error, {:supervisor_module_not_found, supervisor_module}}
        end

      {_app_name, supervisor_module} ->
        {:error, {:invalid_supervisor_module, supervisor_module}}
    end
  end

  defp validate_sandbox_path(opts) do
    sandbox_path = Keyword.get(opts, :sandbox_path)

    cond do
      is_nil(sandbox_path) ->
        {:ok, default_sandbox_path(:sandbox)}

      not is_binary(sandbox_path) ->
        {:error,
         {:invalid_sandbox_path, "sandbox_path must be a string, got: #{inspect(sandbox_path)}"}}

      not File.exists?(sandbox_path) ->
        {:error, {:sandbox_path_not_found, "sandbox_path does not exist: #{sandbox_path}"}}

      not File.dir?(sandbox_path) ->
        {:error,
         {:sandbox_path_not_directory,
          "sandbox_path must be a directory, got file: #{sandbox_path}"}}

      true ->
        case validate_sandbox_directory_structure(sandbox_path) do
          :ok ->
            {:ok, Path.expand(sandbox_path)}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Validates that the sandbox directory has the required structure for compilation.
  # A valid sandbox directory should contain:
  # - mix.exs file (required for Mix project)
  # - lib/ directory (optional but recommended)
  # - Readable permissions
  defp validate_sandbox_directory_structure(sandbox_path) do
    expanded_path = Path.expand(sandbox_path)

    with :ok <- validate_directory_permissions(expanded_path),
         :ok <- validate_mix_project_file(expanded_path),
         :ok <- validate_lib_directory(expanded_path) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_directory_permissions(sandbox_path) do
    case File.stat(sandbox_path) do
      {:ok, %File.Stat{access: access}} when access in [:read, :read_write] ->
        :ok

      {:ok, %File.Stat{access: access}} ->
        {:error,
         {:sandbox_path_permission_denied,
          "insufficient permissions for sandbox directory: #{sandbox_path}, access: #{access}"}}

      {:error, reason} ->
        {:error,
         {:sandbox_path_stat_failed,
          "failed to read sandbox directory permissions: #{sandbox_path}, reason: #{inspect(reason)}"}}
    end
  end

  defp validate_mix_project_file(sandbox_path) do
    mix_file = Path.join(sandbox_path, "mix.exs")

    cond do
      not File.exists?(mix_file) ->
        {:error,
         {:sandbox_missing_mix_file, "sandbox directory must contain mix.exs file: #{mix_file}"}}

      not File.regular?(mix_file) ->
        {:error, {:sandbox_invalid_mix_file, "mix.exs must be a regular file: #{mix_file}"}}

      true ->
        validate_mix_project_content(mix_file)
    end
  end

  defp validate_mix_project_content(mix_file) do
    case File.read(mix_file) do
      {:ok, content} ->
        if String.contains?(content, "defmodule") and String.contains?(content, "MixProject") do
          :ok
        else
          {:error,
           {:sandbox_invalid_mix_content,
            "mix.exs does not appear to contain a valid Mix project definition"}}
        end

      {:error, reason} ->
        {:error, {:sandbox_mix_file_unreadable, "cannot read mix.exs file: #{inspect(reason)}"}}
    end
  end

  defp validate_lib_directory(sandbox_path) do
    lib_dir = Path.join(sandbox_path, "lib")

    cond do
      not File.exists?(lib_dir) ->
        # lib directory is optional, but we'll create it if it doesn't exist
        case File.mkdir_p(lib_dir) do
          :ok ->
            Logger.info("Created lib directory for sandbox", path: lib_dir)
            :ok

          {:error, reason} ->
            {:error,
             {:sandbox_lib_dir_creation_failed,
              "failed to create lib directory: #{lib_dir}, reason: #{inspect(reason)}"}}
        end

      not File.dir?(lib_dir) ->
        {:error,
         {:sandbox_lib_not_directory, "lib path exists but is not a directory: #{lib_dir}"}}

      true ->
        case File.stat(lib_dir) do
          {:ok, %File.Stat{access: access}} when access in [:read, :read_write] ->
            :ok

          {:ok, %File.Stat{access: access}} ->
            {:error,
             {:sandbox_lib_permission_denied,
              "insufficient permissions for lib directory: #{lib_dir}, access: #{access}"}}

          {:error, reason} ->
            {:error,
             {:sandbox_lib_stat_failed,
              "failed to read lib directory permissions: #{lib_dir}, reason: #{inspect(reason)}"}}
        end
    end
  end

  defp validate_resource_limits(opts) do
    default_limits = %{
      # 128MB
      max_memory: 128 * 1024 * 1024,
      max_processes: 100,
      # 5 minutes
      max_execution_time: 300_000,
      # 10MB
      max_file_size: 10 * 1024 * 1024,
      max_cpu_percentage: 50.0
    }

    case Keyword.get(opts, :resource_limits, default_limits) do
      limits when is_map(limits) ->
        case validate_resource_limit_values(limits, default_limits) do
          {:ok, validated_limits} -> {:ok, validated_limits}
          {:error, errors} -> {:error, {:invalid_resource_limit_values, errors}}
        end

      invalid ->
        {:error,
         {:invalid_resource_limits, "resource_limits must be a map, got: #{inspect(invalid)}"}}
    end
  end

  # Validates individual resource limit values and merges with defaults.
  defp validate_resource_limit_values(limits, defaults) do
    errors = []

    # Validate each limit value
    errors = validate_memory_limit(Map.get(limits, :max_memory), errors)
    errors = validate_process_limit(Map.get(limits, :max_processes), errors)
    errors = validate_execution_time_limit(Map.get(limits, :max_execution_time), errors)
    errors = validate_file_size_limit(Map.get(limits, :max_file_size), errors)
    errors = validate_cpu_percentage_limit(Map.get(limits, :max_cpu_percentage), errors)

    case errors do
      [] ->
        # Merge with defaults and ensure all values are within reasonable bounds
        validated_limits =
          defaults
          |> Map.merge(limits)
          |> enforce_resource_limit_bounds()

        {:ok, validated_limits}

      errors ->
        {:error, Enum.reverse(errors)}
    end
  end

  defp validate_memory_limit(nil, errors), do: errors

  defp validate_memory_limit(value, errors) when is_integer(value) and value > 0 do
    cond do
      # Less than 1MB
      value < 1024 * 1024 ->
        [
          {:max_memory_too_small,
           "max_memory must be at least 1MB (1048576 bytes), got: #{value}"}
          | errors
        ]

      # More than 2GB
      value > 2 * 1024 * 1024 * 1024 ->
        [
          {:max_memory_too_large,
           "max_memory must be at most 2GB (2147483648 bytes), got: #{value}"}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_memory_limit(value, errors) do
    [
      {:invalid_max_memory,
       "max_memory must be a positive integer (bytes), got: #{inspect(value)}"}
      | errors
    ]
  end

  defp validate_process_limit(nil, errors), do: errors

  defp validate_process_limit(value, errors) when is_integer(value) and value > 0 do
    if value > 10_000 do
      [{:max_processes_too_large, "max_processes must be at most 10000, got: #{value}"} | errors]
    else
      errors
    end
  end

  defp validate_process_limit(value, errors) do
    [
      {:invalid_max_processes, "max_processes must be a positive integer, got: #{inspect(value)}"}
      | errors
    ]
  end

  defp validate_execution_time_limit(nil, errors), do: errors

  defp validate_execution_time_limit(value, errors) when is_integer(value) and value > 0 do
    cond do
      # Less than 1 second
      value < 1000 ->
        [
          {:max_execution_time_too_small,
           "max_execution_time must be at least 1000ms (1 second), got: #{value}"}
          | errors
        ]

      # More than 1 hour
      value > 3_600_000 ->
        [
          {:max_execution_time_too_large,
           "max_execution_time must be at most 3600000ms (1 hour), got: #{value}"}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_execution_time_limit(value, errors) do
    [
      {:invalid_max_execution_time,
       "max_execution_time must be a positive integer (milliseconds), got: #{inspect(value)}"}
      | errors
    ]
  end

  defp validate_file_size_limit(nil, errors), do: errors

  defp validate_file_size_limit(value, errors) when is_integer(value) and value > 0 do
    cond do
      # Less than 1KB
      value < 1024 ->
        [
          {:max_file_size_too_small,
           "max_file_size must be at least 1024 bytes (1KB), got: #{value}"}
          | errors
        ]

      # More than 100MB
      value > 100 * 1024 * 1024 ->
        [
          {:max_file_size_too_large,
           "max_file_size must be at most 104857600 bytes (100MB), got: #{value}"}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_file_size_limit(value, errors) do
    [
      {:invalid_max_file_size,
       "max_file_size must be a positive integer (bytes), got: #{inspect(value)}"}
      | errors
    ]
  end

  defp validate_cpu_percentage_limit(nil, errors), do: errors

  defp validate_cpu_percentage_limit(value, errors) when is_number(value) and value > 0 do
    cond do
      value > 100.0 ->
        [
          {:max_cpu_percentage_too_large,
           "max_cpu_percentage must be at most 100.0, got: #{value}"}
          | errors
        ]

      value < 1.0 ->
        [
          {:max_cpu_percentage_too_small,
           "max_cpu_percentage must be at least 1.0, got: #{value}"}
          | errors
        ]

      true ->
        errors
    end
  end

  defp validate_cpu_percentage_limit(value, errors) do
    [
      {:invalid_max_cpu_percentage,
       "max_cpu_percentage must be a positive number (percentage), got: #{inspect(value)}"}
      | errors
    ]
  end

  defp enforce_resource_limit_bounds(limits) do
    limits
    # At least 1MB
    |> Map.update(:max_memory, 128 * 1024 * 1024, &max(&1, 1024 * 1024))
    # At least 1 process
    |> Map.update(:max_processes, 100, &max(&1, 1))
    # At least 1 second
    |> Map.update(:max_execution_time, 300_000, &max(&1, 1000))
    # At least 1KB
    |> Map.update(:max_file_size, 10 * 1024 * 1024, &max(&1, 1024))
    # At least 1%
    |> Map.update(:max_cpu_percentage, 50.0, &max(&1, 1.0))
  end

  defp validate_security_profile(opts) do
    case Keyword.get(opts, :security_profile, :medium) do
      profile_name when is_atom(profile_name) ->
        validate_named_security_profile(profile_name)

      custom_profile when is_map(custom_profile) ->
        validate_custom_security_profile(custom_profile)

      invalid ->
        {:error,
         {:invalid_security_profile_type,
          "security_profile must be an atom (:high, :medium, :low) or a custom profile map, got: #{inspect(invalid)}"}}
    end
  end

  defp validate_named_security_profile(profile_name) do
    case get_security_profile(profile_name) do
      {:ok, profile} ->
        case validate_security_profile_consistency(profile) do
          :ok -> {:ok, profile}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Gets predefined security profiles with comprehensive settings.
  defp get_security_profile(:high) do
    {:ok,
     %{
       isolation_level: :high,
       allowed_operations: [:basic_otp, :math, :string, :enum, :stream],
       restricted_modules: [:file, :os, :code, :system, :port, :node],
       audit_level: :full,
       # 1MB per module
       max_module_size: 1024 * 1024,
       allow_dynamic_code: false,
       allow_network_access: false,
       allow_file_system_access: false
     }}
  end

  defp get_security_profile(:medium) do
    {:ok,
     %{
       isolation_level: :medium,
       allowed_operations: [
         :basic_otp,
         :file_read,
         :network_client,
         :math,
         :string,
         :enum,
         :stream,
         :json
       ],
       restricted_modules: [:os, :code, :system, :port],
       audit_level: :basic,
       # 5MB per module
       max_module_size: 5 * 1024 * 1024,
       allow_dynamic_code: false,
       allow_network_access: true,
       allow_file_system_access: :read_only
     }}
  end

  defp get_security_profile(:low) do
    {:ok,
     %{
       isolation_level: :low,
       allowed_operations: [:all],
       restricted_modules: [],
       audit_level: :basic,
       # 10MB per module
       max_module_size: 10 * 1024 * 1024,
       allow_dynamic_code: true,
       allow_network_access: true,
       allow_file_system_access: :read_write
     }}
  end

  defp get_security_profile(invalid) do
    {:error,
     {:invalid_security_profile_name,
      "security_profile must be :high, :medium, or :low, got: #{inspect(invalid)}"}}
  end

  # Validates a custom security profile map.
  defp validate_custom_security_profile(profile) do
    required_keys = [:isolation_level, :allowed_operations, :restricted_modules, :audit_level]
    errors = []

    # Check required keys
    errors =
      Enum.reduce(required_keys, errors, fn key, acc ->
        if Map.has_key?(profile, key) do
          acc
        else
          [
            {:missing_security_profile_key,
             "custom security profile missing required key: #{key}"}
            | acc
          ]
        end
      end)

    # Validate individual fields
    errors = validate_isolation_level(Map.get(profile, :isolation_level), errors)
    errors = validate_allowed_operations(Map.get(profile, :allowed_operations), errors)
    errors = validate_restricted_modules(Map.get(profile, :restricted_modules), errors)
    errors = validate_audit_level(Map.get(profile, :audit_level), errors)

    case errors do
      [] ->
        # Add defaults for optional fields
        complete_profile =
          profile
          |> Map.put_new(:max_module_size, 5 * 1024 * 1024)
          |> Map.put_new(:allow_dynamic_code, false)
          |> Map.put_new(:allow_network_access, false)
          |> Map.put_new(:allow_file_system_access, false)

        # Validate consistency of the complete profile
        case validate_security_profile_consistency(complete_profile) do
          :ok -> {:ok, complete_profile}
          {:error, reason} -> {:error, reason}
        end

      errors ->
        {:error, {:invalid_custom_security_profile, Enum.reverse(errors)}}
    end
  end

  defp validate_isolation_level(level, errors) when level in [:high, :medium, :low], do: errors

  defp validate_isolation_level(level, errors) do
    [
      {:invalid_isolation_level,
       "isolation_level must be :high, :medium, or :low, got: #{inspect(level)}"}
      | errors
    ]
  end

  defp validate_allowed_operations(ops, errors) when is_list(ops) do
    valid_operations = [
      :basic_otp,
      :math,
      :string,
      :enum,
      :stream,
      :file_read,
      :file_write,
      :network_client,
      :network_server,
      :json,
      :crypto,
      :all
    ]

    invalid_ops = ops -- valid_operations

    case invalid_ops do
      [] ->
        errors

      invalid ->
        [
          {:invalid_allowed_operations,
           "unknown operations: #{inspect(invalid)}, valid operations: #{inspect(valid_operations)}"}
          | errors
        ]
    end
  end

  defp validate_allowed_operations(ops, errors) do
    [
      {:invalid_allowed_operations_type,
       "allowed_operations must be a list of atoms, got: #{inspect(ops)}"}
      | errors
    ]
  end

  defp validate_restricted_modules(modules, errors) when is_list(modules) do
    # All modules should be atoms
    non_atoms = Enum.reject(modules, &is_atom/1)

    case non_atoms do
      [] ->
        errors

      invalid ->
        [
          {:invalid_restricted_modules,
           "restricted_modules must be a list of atoms, found non-atoms: #{inspect(invalid)}"}
          | errors
        ]
    end
  end

  defp validate_restricted_modules(modules, errors) do
    [
      {:invalid_restricted_modules_type,
       "restricted_modules must be a list of atoms, got: #{inspect(modules)}"}
      | errors
    ]
  end

  defp validate_audit_level(level, errors) when level in [:full, :basic, :none], do: errors

  defp validate_audit_level(level, errors) do
    [
      {:invalid_audit_level,
       "audit_level must be :full, :basic, or :none, got: #{inspect(level)}"}
      | errors
    ]
  end

  # Validates that the security profile settings are internally consistent.
  defp validate_security_profile_consistency(profile) do
    %{isolation_level: level, allowed_operations: ops, restricted_modules: _restricted} = profile

    # High isolation should not allow dangerous operations
    case level do
      :high ->
        validate_high_isolation_operations(ops)

      _ ->
        :ok
    end
  end

  defp validate_high_isolation_operations(ops) do
    if :all in ops do
      {:error,
       {:security_profile_inconsistent, "high isolation level cannot allow :all operations"}}
    else
      dangerous_ops = [:file_write, :network_server, :crypto]
      allowed_dangerous = Enum.filter(dangerous_ops, &(&1 in ops))

      if allowed_dangerous != [] do
        {:error,
         {:security_profile_inconsistent,
          "high isolation level should not allow dangerous operations: #{inspect(allowed_dangerous)}"}}
      else
        :ok
      end
    end
  end

  defp create_sandbox_with_monitoring(
         sandbox_id,
         {sandbox_id, app_name, supervisor_module, config},
         state
       ) do
    # Create sandbox state with proper initialization
    sandbox_state = SandboxState.new(sandbox_id, app_name, supervisor_module, config)

    # Update status to compiling
    sandbox_state = SandboxState.update_status(sandbox_state, :compiling)

    # Store initial state
    :ets.insert(state.tables.sandboxes, {sandbox_id, SandboxState.to_info(sandbox_state)})
    new_state = %{state | sandboxes: Map.put(state.sandboxes, sandbox_id, {sandbox_state, nil})}

    # Start sandbox application with comprehensive monitoring
    case start_sandbox_application_with_monitoring(
           sandbox_state,
           state.services,
           state.table_prefixes
         ) do
      {:ok, updated_sandbox_state, monitor_ref} ->
        # Update state with process information
        :ets.insert(
          state.tables.sandboxes,
          {sandbox_id, SandboxState.to_info(updated_sandbox_state)}
        )

        :ets.insert(state.tables.sandbox_monitors, {monitor_ref, sandbox_id})

        final_state = %{
          new_state
          | sandboxes:
              Map.put(new_state.sandboxes, sandbox_id, {updated_sandbox_state, monitor_ref}),
            monitors: Map.put(new_state.monitors, monitor_ref, sandbox_id)
        }

        Logger.info("Successfully created sandbox with comprehensive monitoring",
          sandbox_id: sandbox_id,
          app_name: app_name,
          supervisor_module: supervisor_module,
          app_pid: updated_sandbox_state.app_pid
        )

        {:reply, {:ok, SandboxState.to_info(updated_sandbox_state)}, final_state}

      {:error, reason} ->
        # Cleanup failed sandbox
        :ets.delete(state.tables.sandboxes, sandbox_id)
        cleanup_state = Map.delete(new_state.sandboxes, sandbox_id)

        Logger.error("Failed to create sandbox",
          sandbox_id: sandbox_id,
          reason: inspect(reason)
        )

        {:reply, {:error, reason}, %{new_state | sandboxes: cleanup_state}}
    end
  end

  defp start_sandbox_application_with_monitoring(sandbox_state, services, table_prefixes) do
    %SandboxState{
      id: _sandbox_id,
      app_name: _app_name,
      supervisor_module: _supervisor_module,
      config: config
    } = sandbox_state

    # Check isolation mode
    isolation_mode = Map.get(config, :isolation_mode, :hybrid)

    case isolation_mode do
      :process ->
        # Pure process isolation (Phase 2)
        start_with_process_isolation(sandbox_state, services, table_prefixes)

      :module ->
        # Pure module transformation (Phase 1)
        start_with_module_transformation(sandbox_state, services, table_prefixes)

      :hybrid ->
        # Combined approach (Phase 1 + Phase 2) - default
        start_with_hybrid_isolation(sandbox_state, services, table_prefixes)

      :ets ->
        # ETS-based virtual code tables (Phase 3)
        start_with_ets_isolation(sandbox_state, services, table_prefixes)
    end
  end

  defp start_with_process_isolation(sandbox_state, services, table_prefixes) do
    %SandboxState{
      id: _sandbox_id,
      app_name: _app_name,
      supervisor_module: _supervisor_module,
      config: config
    } = sandbox_state

    # First apply module transformation if sandbox_path is provided
    case Map.get(config, :sandbox_path) do
      nil ->
        # No sandbox path, use pure process isolation without module compilation
        create_pure_process_isolation(sandbox_state, services)

      _sandbox_path ->
        # Apply module transformation first, then process isolation
        start_process_isolation_with_compilation(sandbox_state, services, table_prefixes)
    end
  end

  defp start_process_isolation_with_compilation(sandbox_state, services, table_prefixes) do
    %SandboxState{
      id: sandbox_id,
      app_name: app_name,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    case start_sandbox_application(
           sandbox_id,
           app_name,
           supervisor_module,
           Map.to_list(config),
           services,
           table_prefixes
         ) do
      {:ok, app_pid, supervisor_pid, full_opts} ->
        finalize_process_isolation(sandbox_state, services, app_pid, supervisor_pid, full_opts)

      {:error, reason} ->
        SandboxState.update_status(sandbox_state, :error)
        {:error, {:process_isolation_failed, reason}}
    end
  end

  defp finalize_process_isolation(sandbox_state, services, app_pid, supervisor_pid, full_opts) do
    %SandboxState{
      id: sandbox_id,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    # Also create isolated process context for additional isolation
    isolation_opts = [
      isolation_level: Map.get(config, :isolation_level, :medium),
      communication_mode: Map.get(config, :communication_mode, :message_passing),
      resource_limits: Map.get(config, :resource_limits, %{})
    ]

    # Create additional process isolation context
    isolation_result =
      ProcessIsolator.create_isolated_context(
        "#{sandbox_id}_process_wrapper",
        supervisor_module,
        Keyword.put(isolation_opts, :server, services.process_isolator)
      )

    # Set up comprehensive process monitoring
    monitor_ref = Process.monitor(supervisor_pid)

    # Extract compile info to track sandbox directory for cleanup
    compile_info = Keyword.get(full_opts, :compile_info, %{})
    sandbox_path = Keyword.get(full_opts, :sandbox_path)

    # Build list of artifacts including the unique sandbox directory
    artifacts = build_compilation_artifacts(sandbox_path, compile_info)

    # Update sandbox state with process isolation information
    isolation_context = extract_isolation_context(isolation_result)

    namespace_prefix = namespace_prefix_from_opts(full_opts)

    updated_state =
      sandbox_state
      |> SandboxState.update_processes(app_pid, supervisor_pid, monitor_ref)
      |> SandboxState.update_status(:running)
      |> Map.put(:compilation_artifacts, artifacts)
      |> Map.put(:module_namespace_prefix, namespace_prefix)
      |> Map.put(:isolation_mode, :process)
      |> Map.put(:isolation_context, isolation_context)

    {:ok, updated_state, monitor_ref}
  end

  defp build_compilation_artifacts(sandbox_path, compile_info) do
    if sandbox_path && String.starts_with?(sandbox_path, System.tmp_dir!()) do
      [sandbox_path | Map.get(compile_info, :beam_files, [])]
    else
      Map.get(compile_info, :beam_files, [])
    end
  end

  defp extract_isolation_context(isolation_result) do
    case isolation_result do
      {:ok, context} -> context
      {:error, _} -> nil
    end
  end

  defp create_pure_process_isolation(sandbox_state, services) do
    %SandboxState{
      id: sandbox_id,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    # Create isolated process context without module compilation
    isolation_opts = [
      isolation_level: Map.get(config, :isolation_level, :medium),
      communication_mode: Map.get(config, :communication_mode, :message_passing),
      resource_limits: Map.get(config, :resource_limits, %{})
    ]

    case ProcessIsolator.create_isolated_context(
           sandbox_id,
           supervisor_module,
           Keyword.put(isolation_opts, :server, services.process_isolator)
         ) do
      {:ok, context} ->
        # Monitor the isolated process
        monitor_ref = Process.monitor(context.isolated_pid)

        # Update sandbox state with isolation information
        updated_state =
          sandbox_state
          |> SandboxState.update_processes(nil, context.isolated_pid, monitor_ref)
          |> SandboxState.update_status(:running)
          |> Map.put(:isolation_context, context)
          |> Map.put(:isolation_mode, :process)

        {:ok, updated_state, monitor_ref}

      {:error, reason} ->
        SandboxState.update_status(sandbox_state, :error)
        {:error, {:process_isolation_failed, reason}}
    end
  end

  defp start_with_module_transformation(sandbox_state, services, table_prefixes) do
    %SandboxState{
      id: sandbox_id,
      app_name: app_name,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    # Start sandbox application with module transformation (existing logic)
    case start_sandbox_application(
           sandbox_id,
           app_name,
           supervisor_module,
           Map.to_list(config),
           services,
           table_prefixes
         ) do
      {:ok, app_pid, supervisor_pid, full_opts} ->
        # Set up comprehensive process monitoring
        monitor_ref = Process.monitor(supervisor_pid)

        # Extract compile info to track sandbox directory for cleanup
        compile_info = Keyword.get(full_opts, :compile_info, %{})
        sandbox_path = Keyword.get(full_opts, :sandbox_path)

        # Build list of artifacts including the unique sandbox directory
        artifacts =
          if sandbox_path && String.starts_with?(sandbox_path, System.tmp_dir!()) do
            [sandbox_path | Map.get(compile_info, :beam_files, [])]
          else
            Map.get(compile_info, :beam_files, [])
          end

        # Update sandbox state with process information and running status
        namespace_prefix = namespace_prefix_from_opts(full_opts)

        updated_state =
          sandbox_state
          |> SandboxState.update_processes(app_pid, supervisor_pid, monitor_ref)
          |> SandboxState.update_status(:running)
          |> Map.put(:compilation_artifacts, artifacts)
          |> Map.put(:module_namespace_prefix, namespace_prefix)
          |> Map.put(:isolation_mode, :module)

        {:ok, updated_state, monitor_ref}

      {:error, reason} ->
        # Update status to error
        _error_state = SandboxState.update_status(sandbox_state, :error)
        {:error, reason}
    end
  end

  defp start_with_hybrid_isolation(sandbox_state, services, table_prefixes) do
    %SandboxState{
      id: sandbox_id,
      app_name: app_name,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    # First apply module transformation, then process isolation
    case start_sandbox_application(
           sandbox_id,
           app_name,
           supervisor_module,
           Map.to_list(config),
           services,
           table_prefixes
         ) do
      {:ok, app_pid, supervisor_pid, full_opts} ->
        # Also create process isolation context for additional isolation
        isolation_opts = [
          # Relaxed since module transformation handles conflicts
          isolation_level: Map.get(config, :isolation_level, :relaxed),
          communication_mode: Map.get(config, :communication_mode, :message_passing),
          resource_limits: Map.get(config, :resource_limits, %{})
        ]

        # Optional: Create additional process isolation
        isolation_result =
          ProcessIsolator.create_isolated_context(
            "#{sandbox_id}_process_wrapper",
            supervisor_module,
            Keyword.put(isolation_opts, :server, services.process_isolator)
          )

        # Set up comprehensive process monitoring
        monitor_ref = Process.monitor(supervisor_pid)

        # Extract compile info to track sandbox directory for cleanup
        compile_info = Keyword.get(full_opts, :compile_info, %{})
        sandbox_path = Keyword.get(full_opts, :sandbox_path)

        # Build list of artifacts including the unique sandbox directory
        artifacts =
          if sandbox_path && String.starts_with?(sandbox_path, System.tmp_dir!()) do
            [sandbox_path | Map.get(compile_info, :beam_files, [])]
          else
            Map.get(compile_info, :beam_files, [])
          end

        # Update sandbox state with hybrid isolation information
        namespace_prefix = namespace_prefix_from_opts(full_opts)

        updated_state =
          sandbox_state
          |> SandboxState.update_processes(app_pid, supervisor_pid, monitor_ref)
          |> SandboxState.update_status(:running)
          |> Map.put(:compilation_artifacts, artifacts)
          |> Map.put(:module_namespace_prefix, namespace_prefix)
          |> Map.put(:isolation_mode, :hybrid)
          |> Map.put(
            :isolation_context,
            case isolation_result do
              {:ok, context} -> context
              {:error, _} -> nil
            end
          )

        {:ok, updated_state, monitor_ref}

      {:error, reason} ->
        # Update status to error
        _error_state = SandboxState.update_status(sandbox_state, :error)
        {:error, reason}
    end
  end

  defp start_with_ets_isolation(sandbox_state, services, table_prefixes) do
    %SandboxState{
      id: _sandbox_id,
      app_name: _app_name,
      supervisor_module: _supervisor_module,
      config: config
    } = sandbox_state

    # Phase 3: ETS-based virtual code tables with optional module transformation
    case Map.get(config, :sandbox_path) do
      nil ->
        # No sandbox path, create ETS table and start supervisor directly
        create_pure_ets_isolation(sandbox_state, table_prefixes)

      _sandbox_path ->
        # Apply module transformation, compile to ETS table, then start supervisor
        start_ets_isolation_with_compilation(sandbox_state, services, table_prefixes)
    end
  end

  defp start_ets_isolation_with_compilation(sandbox_state, services, table_prefixes) do
    case create_ets_virtual_code_table(sandbox_state, table_prefixes) do
      {:ok, table_ref, updated_state} ->
        start_ets_sandbox_application(
          sandbox_state,
          updated_state,
          table_ref,
          services,
          table_prefixes
        )

      {:error, reason} ->
        SandboxState.update_status(sandbox_state, :error)
        {:error, {:ets_table_creation_failed, reason}}
    end
  end

  defp start_ets_sandbox_application(
         sandbox_state,
         updated_state,
         table_ref,
         services,
         table_prefixes
       ) do
    %SandboxState{
      id: sandbox_id,
      app_name: app_name,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    case start_sandbox_application_with_ets(
           sandbox_id,
           app_name,
           supervisor_module,
           Map.to_list(config),
           table_ref,
           services,
           table_prefixes
         ) do
      {:ok, app_pid, supervisor_pid, full_opts} ->
        finalize_ets_isolation(updated_state, table_ref, app_pid, supervisor_pid, full_opts)

      {:error, reason} ->
        # Cleanup ETS table on failure
        VirtualCodeTable.destroy_table(sandbox_id,
          table_prefix: table_prefixes.virtual_code
        )

        SandboxState.update_status(sandbox_state, :error)
        {:error, {:ets_isolation_failed, reason}}
    end
  end

  defp finalize_ets_isolation(updated_state, table_ref, app_pid, supervisor_pid, full_opts) do
    # Set up monitoring
    monitor_ref = Process.monitor(supervisor_pid)

    # Extract compile info
    compile_info = Keyword.get(full_opts, :compile_info, %{})
    sandbox_path = Keyword.get(full_opts, :sandbox_path)

    # Build artifacts list
    artifacts = build_compilation_artifacts(sandbox_path, compile_info)

    # Update sandbox state
    namespace_prefix = namespace_prefix_from_opts(full_opts)

    final_state =
      updated_state
      |> SandboxState.update_processes(app_pid, supervisor_pid, monitor_ref)
      |> SandboxState.update_status(:running)
      |> Map.put(:compilation_artifacts, artifacts)
      |> Map.put(:module_namespace_prefix, namespace_prefix)
      |> Map.put(:isolation_mode, :ets)
      |> Map.put(:virtual_code_table, table_ref)

    {:ok, final_state, monitor_ref}
  end

  defp create_pure_ets_isolation(sandbox_state, table_prefixes) do
    %SandboxState{
      id: sandbox_id,
      supervisor_module: supervisor_module,
      config: _config
    } = sandbox_state

    # Create ETS table without module compilation
    case VirtualCodeTable.create_table(sandbox_id, table_prefix: table_prefixes.virtual_code) do
      {:ok, table_ref} ->
        # Start supervisor directly
        case supervisor_module.start_link([]) do
          {:ok, supervisor_pid} ->
            monitor_ref = Process.monitor(supervisor_pid)

            updated_state =
              sandbox_state
              |> SandboxState.update_processes(nil, supervisor_pid, monitor_ref)
              |> SandboxState.update_status(:running)
              |> Map.put(:isolation_mode, :ets)
              |> Map.put(:virtual_code_table, table_ref)

            {:ok, updated_state, monitor_ref}

          {:error, reason} ->
            VirtualCodeTable.destroy_table(sandbox_id, table_prefix: table_prefixes.virtual_code)
            SandboxState.update_status(sandbox_state, :error)
            {:error, {:supervisor_start_failed, reason}}
        end

      {:error, reason} ->
        SandboxState.update_status(sandbox_state, :error)
        {:error, {:ets_table_creation_failed, reason}}
    end
  end

  defp create_ets_virtual_code_table(sandbox_state, table_prefixes) do
    %SandboxState{
      id: sandbox_id,
      config: _config
    } = sandbox_state

    # Create ETS table for virtual code storage
    case VirtualCodeTable.create_table(sandbox_id, table_prefix: table_prefixes.virtual_code) do
      {:ok, table_ref} ->
        Logger.info("Created virtual code table for sandbox #{sandbox_id}",
          table_ref: table_ref
        )

        updated_state = Map.put(sandbox_state, :virtual_code_table, table_ref)
        {:ok, table_ref, updated_state}

      {:error, reason} ->
        Logger.error("Failed to create virtual code table for sandbox #{sandbox_id}",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp start_sandbox_application_with_ets(
         sandbox_id,
         app_name,
         supervisor_module,
         opts,
         table_ref,
         services,
         table_prefixes
       ) do
    # This would be similar to start_sandbox_application but with ETS integration
    # For now, fall back to standard compilation with ETS storage
    case start_sandbox_application(
           sandbox_id,
           app_name,
           supervisor_module,
           opts,
           services,
           table_prefixes
         ) do
      {:ok, _app_pid, _supervisor_pid, _full_opts} = success ->
        # Note: ETS integration for compiled modules is handled by the standard
        # compilation path. Future enhancement could store BEAM files in the
        # virtual code table for cross-sandbox module sharing.
        Logger.debug("ETS-based sandbox application started",
          sandbox_id: sandbox_id,
          table_ref: table_ref
        )

        success

      error ->
        error
    end
  end

  defp perform_comprehensive_cleanup(sandbox_state, monitor_ref, state) do
    %SandboxState{
      id: sandbox_id,
      app_name: app_name,
      supervisor_pid: supervisor_pid,
      compilation_artifacts: artifacts
    } = sandbox_state

    cleanup_errors = []

    # 1. Stop process monitoring
    cleanup_errors = cleanup_monitoring(monitor_ref, sandbox_id, state, cleanup_errors)

    # 2. Clean up module versions
    cleanup_errors =
      cleanup_module_versions(
        sandbox_id,
        state.services,
        state.table_prefixes,
        cleanup_errors
      )

    # 3. Terminate processes gracefully
    cleanup_errors = cleanup_processes(supervisor_pid, cleanup_errors)

    # 4. Stop sandbox application
    cleanup_errors = cleanup_application(app_name, sandbox_id, cleanup_errors)

    # 5. Clean up compilation artifacts
    cleanup_errors = cleanup_compilation_artifacts(artifacts, cleanup_errors)

    # 6. Remove from ETS tables
    cleanup_errors =
      cleanup_ets_entries(
        sandbox_id,
        monitor_ref,
        state.tables,
        state.table_prefixes,
        cleanup_errors
      )

    # 7. Update state
    updated_state = %{
      state
      | sandboxes: Map.delete(state.sandboxes, sandbox_id),
        monitors: Map.delete(state.monitors, monitor_ref)
    }

    case cleanup_errors do
      [] -> {:ok, updated_state}
      errors -> {:error, errors, updated_state}
    end
  end

  defp cleanup_monitoring(monitor_ref, sandbox_id, _state, errors) do
    if monitor_ref do
      Process.demonitor(monitor_ref, [:flush])
    end

    errors
  rescue
    error ->
      Logger.warning("Error during monitor cleanup",
        sandbox_id: sandbox_id,
        error: inspect(error)
      )

      [{:monitor_cleanup_failed, error} | errors]
  end

  defp cleanup_module_versions(sandbox_id, services, table_prefixes, errors) do
    # Clean up module version manager
    case GenServer.whereis(services.module_version_manager) do
      nil ->
        Logger.debug("ModuleVersionManager not running, skipping module cleanup")

      _pid ->
        ModuleVersionManager.cleanup_sandbox_modules(sandbox_id,
          server: services.module_version_manager
        )
    end

    # Clean up module transformation registry
    ModuleTransformer.destroy_module_registry(sandbox_id,
      table_prefix: table_prefixes.module_registry
    )

    # Clean up process isolation context
    case GenServer.whereis(services.process_isolator) do
      nil ->
        Logger.debug("ProcessIsolator not running, skipping process isolation cleanup")

      _pid ->
        # Clean up main context
        ProcessIsolator.destroy_isolated_context(sandbox_id,
          server: services.process_isolator
        )

        # Clean up hybrid wrapper context if it exists
        ProcessIsolator.destroy_isolated_context("#{sandbox_id}_process_wrapper",
          server: services.process_isolator
        )
    end

    errors
  rescue
    error ->
      Logger.warning("Error during module version cleanup",
        sandbox_id: sandbox_id,
        error: inspect(error)
      )

      [{:module_cleanup_failed, error} | errors]
  end

  defp cleanup_processes(supervisor_pid, errors) do
    if supervisor_pid && Process.alive?(supervisor_pid) do
      terminate_supervisor_gracefully(supervisor_pid)
    end

    errors
  rescue
    error ->
      Logger.warning("Error during process cleanup",
        supervisor_pid: supervisor_pid,
        error: inspect(error)
      )

      [{:process_cleanup_failed, error} | errors]
  end

  defp cleanup_application(app_name, sandbox_id, errors) do
    stop_sandbox_application(app_name, sandbox_id)
    errors
  rescue
    error ->
      Logger.warning("Error during application cleanup",
        app_name: app_name,
        sandbox_id: sandbox_id,
        error: inspect(error)
      )

      [{:application_cleanup_failed, error} | errors]
  end

  defp cleanup_compilation_artifacts(artifacts, errors) do
    Enum.each(artifacts, fn artifact_path ->
      if File.exists?(artifact_path) do
        File.rm_rf!(artifact_path)
      end
    end)

    errors
  rescue
    error ->
      Logger.warning("Error during artifact cleanup",
        artifacts: artifacts,
        error: inspect(error)
      )

      [{:artifact_cleanup_failed, error} | errors]
  end

  defp cleanup_ets_entries(sandbox_id, monitor_ref, tables, table_prefixes, errors) do
    :ets.delete(tables.sandboxes, sandbox_id)

    if monitor_ref do
      :ets.delete(tables.sandbox_monitors, monitor_ref)
    end

    # Cleanup virtual code table if it exists
    case VirtualCodeTable.destroy_table(sandbox_id, table_prefix: table_prefixes.virtual_code) do
      :ok ->
        Logger.debug("Cleaned up virtual code table for sandbox #{sandbox_id}")

      {:error, :table_not_found} ->
        # Table doesn't exist, which is fine
        :ok
    end

    errors
  rescue
    error ->
      Logger.warning("Error during ETS cleanup",
        sandbox_id: sandbox_id,
        error: inspect(error)
      )

      [{:ets_cleanup_failed, error} | errors]
  end

  defp terminate_supervisor_gracefully(supervisor_pid) do
    Logger.debug("Starting supervisor termination", pid: supervisor_pid)

    # Enhanced graceful termination with timeout
    monitor_ref = Process.monitor(supervisor_pid)
    Logger.debug("Monitoring supervisor", pid: supervisor_pid, ref: monitor_ref)

    Process.exit(supervisor_pid, :shutdown)
    Logger.debug("Sent shutdown signal to supervisor", pid: supervisor_pid)

    receive do
      {:DOWN, ^monitor_ref, :process, ^supervisor_pid, reason} ->
        Logger.debug("Supervisor terminated", pid: supervisor_pid, reason: reason)
        :ok
    after
      5000 ->
        # Force kill if graceful shutdown takes too long
        Logger.warning("Supervisor graceful shutdown timed out, force killing",
          pid: supervisor_pid
        )

        Process.demonitor(monitor_ref, [:flush])

        if Process.alive?(supervisor_pid) do
          Process.exit(supervisor_pid, :kill)
          Logger.debug("Force killed supervisor", pid: supervisor_pid)
        end

        :ok
    end
  end

  defp perform_graceful_restart(sandbox_state, monitor_ref, state) do
    %SandboxState{
      id: sandbox_id,
      app_name: _app_name,
      supervisor_module: _supervisor_module,
      config: _config
    } = sandbox_state

    Logger.debug("Starting graceful restart", sandbox_id: sandbox_id)

    try do
      # 1. Stop monitoring current process
      if monitor_ref do
        Logger.debug("Demonitoring process", sandbox_id: sandbox_id, ref: inspect(monitor_ref))
        Process.demonitor(monitor_ref, [:flush])
      end

      # 2. Attempt to preserve state (if state migration handler is configured)
      Logger.debug("Attempting state preservation", sandbox_id: sandbox_id)
      preserved_state = attempt_state_preservation(sandbox_state)

      # 3. Stop current application gracefully
      Logger.debug("Stopping application gracefully", sandbox_id: sandbox_id)

      case graceful_application_stop(sandbox_state) do
        :ok ->
          Logger.debug("Application stopped successfully", sandbox_id: sandbox_id)

          # 4. Increment restart count and update status
          restarting_state =
            sandbox_state
            |> SandboxState.increment_restart_count()
            |> SandboxState.update_status(:starting)

          Logger.debug("Starting new application",
            sandbox_id: sandbox_id,
            restart_count: restarting_state.restart_count
          )

          # 5. Start new application with preserved state
          case start_sandbox_application_with_monitoring(
                 restarting_state,
                 state.services,
                 state.table_prefixes
               ) do
            {:ok, new_sandbox_state, new_monitor_ref} ->
              Logger.debug("New application started successfully",
                sandbox_id: sandbox_id,
                new_pid: new_sandbox_state.supervisor_pid
              )

              # 6. Restore preserved state if available
              final_state = restore_preserved_state(new_sandbox_state, preserved_state)

              # 7. Update ETS and state
              :ets.insert(state.tables.sandboxes, {sandbox_id, SandboxState.to_info(final_state)})
              :ets.insert(state.tables.sandbox_monitors, {new_monitor_ref, sandbox_id})

              updated_state = %{
                state
                | sandboxes: Map.put(state.sandboxes, sandbox_id, {final_state, new_monitor_ref}),
                  monitors:
                    Map.put(Map.delete(state.monitors, monitor_ref), new_monitor_ref, sandbox_id)
              }

              Logger.debug("Restart completed successfully", sandbox_id: sandbox_id)
              {:ok, final_state, new_monitor_ref, updated_state}

            {:error, reason} ->
              Logger.error("Failed to start new application during restart",
                sandbox_id: sandbox_id,
                reason: inspect(reason)
              )

              # Cleanup failed restart
              cleanup_state = %{
                state
                | sandboxes: Map.delete(state.sandboxes, sandbox_id),
                  monitors: Map.delete(state.monitors, monitor_ref)
              }

              :ets.delete(state.tables.sandboxes, sandbox_id)

              {:error, {:restart_failed, reason}, cleanup_state}
          end
      end
    rescue
      error ->
        Logger.error("Exception during graceful restart",
          sandbox_id: sandbox_id,
          error: inspect(error),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        # Cleanup on exception
        cleanup_state = %{
          state
          | sandboxes: Map.delete(state.sandboxes, sandbox_id),
            monitors: Map.delete(state.monitors, monitor_ref)
        }

        :ets.delete(state.tables.sandboxes, sandbox_id)

        {:error, {:restart_exception, error}, cleanup_state}
    end
  end

  defp attempt_state_preservation(%SandboxState{config: %{state_migration_handler: handler}})
       when is_function(handler) do
    # This is a placeholder for state preservation logic
    # In a full implementation, this would capture GenServer states
    {:ok, %{preserved_at: DateTime.utc_now(), handler: handler}}
  rescue
    error ->
      Logger.warning("State preservation failed", error: inspect(error))
      {:error, error}
  end

  defp attempt_state_preservation(_sandbox_state) do
    # No state preservation configured
    :no_preservation
  end

  defp graceful_application_stop(%SandboxState{
         app_name: app_name,
         supervisor_pid: supervisor_pid
       }) do
    Logger.debug("Starting graceful application stop",
      app_name: app_name,
      supervisor_pid: supervisor_pid
    )

    try do
      # Stop supervisor gracefully
      if supervisor_pid && Process.alive?(supervisor_pid) do
        Logger.debug("Terminating supervisor", pid: supervisor_pid)
        terminate_supervisor_gracefully(supervisor_pid)
        Logger.debug("Supervisor terminated successfully", pid: supervisor_pid)
      else
        Logger.debug("Supervisor not alive or nil", pid: supervisor_pid)
      end

      # Stop application (this is a no-op in our current implementation)
      Logger.debug("Stopping sandbox application", app_name: app_name)
      stop_sandbox_application(app_name, "restart")
      Logger.debug("Application stopped successfully", app_name: app_name)
      :ok
    rescue
      error ->
        Logger.warning("Graceful application stop failed",
          app_name: app_name,
          supervisor_pid: supervisor_pid,
          error: inspect(error),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__)
        )

        # Return :ok anyway since we want to proceed with restart
        :ok
    end
  end

  defp restore_preserved_state(sandbox_state, {:ok, preserved_state}) do
    # This is a placeholder for state restoration logic
    # In a full implementation, this would restore GenServer states
    Logger.debug("State restoration completed",
      sandbox_id: sandbox_state.id,
      preserved_at: preserved_state[:preserved_at]
    )

    sandbox_state
  end

  defp restore_preserved_state(sandbox_state, _) do
    # No state to restore
    sandbox_state
  end

  defp handle_sandbox_crash(sandbox_id, monitor_ref, pid, reason, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_state, ^monitor_ref} ->
        Logger.warning("Sandbox crashed - performing cleanup and resource recovery",
          sandbox_id: sandbox_id,
          pid: inspect(pid),
          reason: inspect(reason),
          restart_count: sandbox_state.restart_count
        )

        # Update sandbox status to error
        error_state = SandboxState.update_status(sandbox_state, :error)
        :ets.insert(state.tables.sandboxes, {sandbox_id, SandboxState.to_info(error_state)})

        # Perform comprehensive crash cleanup with resource recovery
        case perform_crash_cleanup_with_recovery(sandbox_state, monitor_ref, reason, state) do
          {:ok, updated_state} ->
            Logger.info("Successfully cleaned up crashed sandbox with resource recovery",
              sandbox_id: sandbox_id
            )

            {:noreply, updated_state}

          {:error, cleanup_errors, updated_state} ->
            Logger.error("Sandbox crash cleanup completed with errors",
              sandbox_id: sandbox_id,
              cleanup_errors: cleanup_errors
            )

            {:noreply, updated_state}
        end

      {_different_sandbox_state, different_ref} ->
        Logger.warning("Monitor reference mismatch during crash handling",
          sandbox_id: sandbox_id,
          expected_ref: inspect(monitor_ref),
          actual_ref: inspect(different_ref)
        )

        {:noreply, state}

      nil ->
        Logger.warning("Received DOWN message for unknown sandbox",
          sandbox_id: sandbox_id,
          ref: inspect(monitor_ref)
        )

        {:noreply, state}
    end
  end

  defp perform_crash_cleanup_with_recovery(sandbox_state, monitor_ref, crash_reason, state) do
    %SandboxState{id: sandbox_id} = sandbox_state

    # Classify crash reason for appropriate recovery strategy
    recovery_strategy = classify_crash_and_determine_recovery(crash_reason)

    Logger.info("Applying crash recovery strategy",
      sandbox_id: sandbox_id,
      crash_reason: inspect(crash_reason),
      recovery_strategy: recovery_strategy
    )

    # Perform cleanup with resource recovery
    cleanup_result = perform_comprehensive_cleanup(sandbox_state, monitor_ref, state)

    case cleanup_result do
      {:ok, updated_state} ->
        # Apply recovery strategy if needed
        apply_crash_recovery_strategy(sandbox_state, recovery_strategy, updated_state)

      {:error, errors, updated_state} ->
        {:error, errors, updated_state}
    end
  end

  defp classify_crash_and_determine_recovery(reason) do
    case reason do
      :normal -> :no_recovery
      :shutdown -> :no_recovery
      {:shutdown, _} -> :no_recovery
      :killed -> :cleanup_only
      {:exit, :killed} -> :cleanup_only
      _ -> :full_cleanup
    end
  end

  defp apply_crash_recovery_strategy(_sandbox_state, :no_recovery, updated_state) do
    # Normal shutdown, no special recovery needed
    {:ok, updated_state}
  end

  defp apply_crash_recovery_strategy(sandbox_state, :cleanup_only, updated_state) do
    # Process was killed, ensure thorough cleanup
    %SandboxState{id: sandbox_id, compilation_artifacts: artifacts} = sandbox_state

    # Additional cleanup for killed processes
    try do
      # Clean up any remaining compilation artifacts
      Enum.each(artifacts, fn artifact ->
        if File.exists?(artifact) do
          File.rm_rf!(artifact)
        end
      end)

      {:ok, updated_state}
    rescue
      error ->
        Logger.warning("Additional cleanup failed for killed sandbox",
          sandbox_id: sandbox_id,
          error: inspect(error)
        )

        {:error, [{:additional_cleanup_failed, error}], updated_state}
    end
  end

  defp apply_crash_recovery_strategy(sandbox_state, :full_cleanup, updated_state) do
    # Unexpected crash, perform full resource recovery
    %SandboxState{id: sandbox_id} = sandbox_state

    Logger.info("Performing full resource recovery for crashed sandbox",
      sandbox_id: sandbox_id
    )

    # This is where we would implement additional recovery strategies
    # such as resource leak detection, memory cleanup, etc.
    {:ok, updated_state}
  end

  defp get_detailed_sandbox_info(sandbox_state) do
    %SandboxState{} = sandbox_state

    updated_resource_usage = sandbox_resource_usage(sandbox_state)

    # Convert to info map with updated resource usage
    sandbox_state
    |> SandboxState.update_resource_usage(updated_resource_usage)
    |> SandboxState.to_info()
  end

  defp sandbox_resource_usage(sandbox_state) do
    current_resource_usage =
      case sandbox_state.supervisor_pid do
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            get_real_time_resource_usage(pid)
          else
            sandbox_state.resource_usage
          end

        _ ->
          sandbox_state.resource_usage
      end

    uptime = sandbox_uptime_ms(sandbox_state)
    Map.put(current_resource_usage, :uptime, uptime)
  end

  defp sandbox_uptime_ms(sandbox_state) do
    case sandbox_state.status do
      :running ->
        case sandbox_state.started_at_monotonic_ms do
          start_ms when is_integer(start_ms) ->
            max(System.monotonic_time(:millisecond) - start_ms, 0)

          _ ->
            DateTime.diff(DateTime.utc_now(), sandbox_state.created_at, :millisecond)
        end

      _ ->
        sandbox_state.resource_usage.uptime
    end
  end

  defp get_real_time_resource_usage(pid) do
    pids = collect_process_tree(pid)

    {memory_usage, message_queue} =
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

    %{
      current_memory: memory_usage,
      current_processes: length(pids),
      message_queue: message_queue,
      cpu_usage: 0.0,
      uptime: 0
    }
  rescue
    _ ->
      # Fallback to default values if process info fails
      %{
        current_memory: 0,
        current_processes: 0,
        message_queue: 0,
        cpu_usage: 0.0,
        uptime: 0
      }
  end

  defp collect_process_tree(pid) do
    {pids, _visited} = do_collect_process_tree(pid, MapSet.new())
    Enum.reverse(pids)
  end

  defp do_collect_process_tree(pid, visited) do
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
            {child_descendants, new_visited} = do_collect_process_tree(child_pid, acc_visited)

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

  defp ensure_run_supervisor(%SandboxState{run_supervisor_pid: pid} = sandbox_state)
       when is_pid(pid) do
    if Process.alive?(pid) do
      {:ok, sandbox_state, pid}
    else
      start_run_supervisor(sandbox_state)
    end
  end

  defp ensure_run_supervisor(%SandboxState{} = sandbox_state) do
    start_run_supervisor(sandbox_state)
  end

  defp start_run_supervisor(
         %SandboxState{id: sandbox_id, supervisor_pid: supervisor_pid} = sandbox_state
       ) do
    cond do
      not is_pid(supervisor_pid) ->
        {:error, :supervisor_not_running}

      not Process.alive?(supervisor_pid) ->
        {:error, :supervisor_not_running}

      true ->
        spec =
          Supervisor.child_spec({Task.Supervisor, []}, id: {:sandbox_run_supervisor, sandbox_id})

        case Supervisor.start_child(supervisor_pid, spec) do
          {:ok, pid} ->
            {:ok, %{sandbox_state | run_supervisor_pid: pid}, pid}

          {:error, {:already_started, pid}} ->
            {:ok, %{sandbox_state | run_supervisor_pid: pid}, pid}

          {:error, :already_present} ->
            lookup_existing_run_supervisor(supervisor_pid, sandbox_id, sandbox_state)

          {:error, reason} ->
            {:error, {:run_supervisor_failed, reason}}
        end
    end
  end

  defp lookup_existing_run_supervisor(supervisor_pid, sandbox_id, sandbox_state) do
    supervisor_pid
    |> Supervisor.which_children()
    |> find_run_supervisor_pid(sandbox_id)
    |> case do
      {:ok, pid} ->
        {:ok, %{sandbox_state | run_supervisor_pid: pid}, pid}

      :error ->
        {:error, :run_supervisor_not_found}
    end
  rescue
    ArgumentError ->
      {:error, :run_supervisor_not_found}
  end

  defp find_run_supervisor_pid(children, sandbox_id) do
    children
    |> Enum.find(fn {id, _pid, _type, _modules} ->
      id == {:sandbox_run_supervisor, sandbox_id}
    end)
    |> case do
      {_, pid, _, _} when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  defp parse_module_or_app(module_or_app, opts) do
    case module_or_app do
      module_string when is_binary(module_string) ->
        # Convert string to atom and treat as module
        case String.starts_with?(module_string, "Elixir.") do
          true ->
            module = String.to_atom(module_string)
            {:sandbox, module}

          false ->
            module = String.to_atom("Elixir." <> module_string)
            {:sandbox, module}
        end

      app when is_atom(app) ->
        # Check if it's a known supervisor module
        case to_string(app) do
          "Elixir." <> _ ->
            # It's a module, use default sandbox app
            {:sandbox, app}

          _ ->
            # It's an application name
            supervisor_module = Keyword.get(opts, :supervisor_module)
            {app, supervisor_module}
        end
    end
  end

  defp start_sandbox_application(
         sandbox_id,
         app_name,
         supervisor_module,
         opts,
         services,
         table_prefixes
       ) do
    # Get sandbox path from options or use default
    original_sandbox_path = Keyword.get(opts, :sandbox_path, default_sandbox_path(app_name))

    # Prepare unique sandbox directory to avoid module conflicts
    with {:ok, sandbox_path} <-
           prepare_unique_sandbox_directory(sandbox_id, original_sandbox_path),
         # Compile sandbox application in isolation
         {:ok, compile_info} <-
           compile_sandbox_isolated(sandbox_id, sandbox_path, app_name, opts, table_prefixes),
         # Create the virtual code table to ensure it exists before loading modules
         {:ok, _table_ref} <-
           VirtualCodeTable.create_table(sandbox_id, table_prefix: table_prefixes.virtual_code),
         :ok <- setup_code_paths(sandbox_id, compile_info),
         :ok <- load_sandbox_modules(sandbox_id, compile_info, services, table_prefixes),
         :ok <- maybe_reconsolidate_protocols(compile_info, opts),
         :ok <- load_sandbox_application(app_name, sandbox_id, compile_info.app_file),
         {:ok, app_pid, supervisor_pid} <-
           start_application_and_supervisor(sandbox_id, app_name, supervisor_module, opts) do
      {:ok, app_pid, supervisor_pid,
       opts
       |> Keyword.put(:compile_info, compile_info)
       |> Keyword.put(:sandbox_path, sandbox_path)}
    else
      {:error, reason} ->
        Logger.error("Failed to start sandbox application #{app_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_sandbox_path(app_name) do
    # Default to a examples directory or current directory
    case File.cwd() do
      {:ok, cwd} -> Path.join([cwd, "sandboxes", to_string(app_name)])
      {:error, _} -> Path.join(["/tmp", "sandboxes", to_string(app_name)])
    end
  end

  defp prepare_unique_sandbox_directory(sandbox_id, original_path) do
    # Create a unique directory for this sandbox to avoid file conflicts
    unique_path = Path.join([System.tmp_dir!(), "sandbox_#{sandbox_id}"])

    # If the path already exists (from a previous run), clean it up first
    if File.exists?(unique_path) do
      File.rm_rf!(unique_path)
    end

    # Copy the original sandbox directory to the unique location
    case copy_directory(original_path, unique_path) do
      :ok ->
        Logger.debug("Prepared unique sandbox directory",
          sandbox_id: sandbox_id,
          original_path: original_path,
          unique_path: unique_path
        )

        {:ok, unique_path}

      {:error, reason} ->
        Logger.error("Failed to prepare unique sandbox directory",
          sandbox_id: sandbox_id,
          original_path: original_path,
          reason: reason
        )

        {:error, {:sandbox_preparation_failed, reason}}
    end
  end

  defp copy_directory(source, destination) do
    with :ok <- File.mkdir_p(destination) do
      source
      |> File.ls!()
      |> Enum.reduce(:ok, fn item, acc ->
        case acc do
          :ok -> copy_directory_item(source, destination, item)
          error -> error
        end
      end)
    end
  end

  defp copy_directory_item(source, destination, item) do
    source_item = Path.join(source, item)
    dest_item = Path.join(destination, item)

    if File.dir?(source_item) do
      copy_directory(source_item, dest_item)
    else
      copy_file(source_item, dest_item)
    end
  end

  defp copy_file(source_item, dest_item) do
    case File.copy(source_item, dest_item) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp setup_code_paths(_sandbox_id, _compile_info) do
    # This is now a no-op for ETS-based isolation. We must not modify the
    # global VM code path to ensure true sandbox isolation. Modules will be
    # loaded into a sandbox-specific VirtualCodeTable (ETS) instead.
    Logger.debug("Skipping global code path modification for ETS isolation mode.")
    :ok
  end

  defp start_application_and_supervisor(sandbox_id, app_name, supervisor_module, opts) do
    case Application.start(app_name) do
      :ok ->
        start_supervisor_in_application(sandbox_id, supervisor_module, opts)

      {:error, {:already_started, ^app_name}} ->
        start_supervisor_in_application(sandbox_id, supervisor_module, opts)

      {:error, reason} ->
        Logger.error("Failed to start application #{app_name}: #{inspect(reason)}")
        {:error, {:start_failed, reason}}
    end
  end

  defp start_supervisor_in_application(sandbox_id, supervisor_module, opts) do
    # Generate unique supervisor name
    unique_id = :erlang.unique_integer([:positive])
    supervisor_name = :"#{supervisor_module}_#{sandbox_id}_#{unique_id}"

    supervisor_opts =
      Keyword.merge(opts,
        name: supervisor_name,
        unique_id: unique_id
      )

    case supervisor_module.start_link(supervisor_opts) do
      {:ok, pid} ->
        # Unlink the supervisor from the Manager to prevent cascade failures
        Process.unlink(pid)

        Logger.debug("Started and unlinked supervisor",
          supervisor_module: supervisor_module,
          pid: pid,
          sandbox_id: sandbox_id
        )

        {:ok, pid, pid}

      {:error, reason} ->
        Logger.error("Failed to start supervisor #{supervisor_module}: #{inspect(reason)}")
        {:error, {:supervisor_start_failed, reason}}
    end
  end

  defp stop_sandbox_application(_app_name, _sandbox_id) do
    # With the new approach, we don't stop the shared application
    # The supervisor termination handles the cleanup
    :ok
  end

  defp compile_sandbox_isolated(sandbox_id, sandbox_path, app_name, opts, table_prefixes) do
    # Step 1: Apply module transformation to source files
    case apply_module_transformation(sandbox_id, sandbox_path, table_prefixes, opts) do
      {:ok, transformation_info} ->
        protocol_consolidation = Keyword.get(opts, :protocol_consolidation, :reconsolidate)

        compile_opts = [
          timeout: Keyword.get(opts, :compile_timeout, 30_000),
          validate_beams: Keyword.get(opts, :validate_beams, true),
          compiler: :elixirc,
          in_process: true,
          parallel: true,
          env: %{
            "MIX_ENV" => "dev",
            "MIX_TARGET" => "host"
          }
        ]

        compile_opts =
          compile_opts
          |> maybe_add_source_files(transformation_info)
          |> maybe_ignore_consolidated_protocols(protocol_consolidation)
          |> apply_resource_limits(Keyword.get(opts, :resource_limits, %{}))
          |> add_security_opts(Keyword.get(opts, :security_profile, %{}))

        Logger.info("Compiling sandbox #{sandbox_id} in isolation with module transformation",
          sandbox_path: sandbox_path,
          app_name: app_name,
          transformed_modules: map_size(transformation_info.module_mappings)
        )

        # Step 2: Compile with transformed modules
        case IsolatedCompiler.compile_sandbox(sandbox_path, compile_opts) do
          {:ok, compile_info} ->
            Logger.info("Successfully compiled sandbox #{sandbox_id}",
              compilation_time: compile_info.compilation_time,
              beam_files: length(compile_info.beam_files),
              module_transformations: map_size(transformation_info.module_mappings)
            )

            # Merge transformation info into compile info
            enhanced_compile_info =
              Map.merge(compile_info, %{
                module_transformation: transformation_info
              })

            {:ok, enhanced_compile_info}

          {:error, reason} ->
            report = IsolatedCompiler.compilation_report({:error, reason})

            Logger.error("Failed to compile sandbox #{sandbox_id}",
              reason: inspect(reason),
              details: report.details
            )

            {:error, reason}
        end

      {:error, transformation_error} ->
        Logger.error("Failed to transform modules for sandbox #{sandbox_id}",
          reason: inspect(transformation_error)
        )

        {:error, {:module_transformation_failed, transformation_error}}
    end
  end

  defp apply_module_transformation(sandbox_id, sandbox_path, table_prefixes, opts) do
    sanitized_id = ModuleTransformer.sanitize_sandbox_id(sandbox_id)
    namespace_prefix = ModuleTransformer.create_unique_namespace(sanitized_id)

    # Create module registry for this sandbox
    ModuleTransformer.create_module_registry(sandbox_id,
      table_prefix: table_prefixes.module_registry
    )

    try do
      # Find all .ex files in the sandbox, excluding dev/test tooling
      ex_files =
        sandbox_path
        |> then(&Path.join([&1, "**", "*.ex"]))
        |> Path.wildcard()
        |> filter_source_files(sandbox_path, opts)

      transform_modules = collect_transform_modules(ex_files)

      transformation_info = %{
        sandbox_id: sandbox_id,
        module_mappings: %{},
        transformed_files: [],
        total_files: length(ex_files),
        source_files: ex_files,
        namespace_prefix: namespace_prefix
      }

      Logger.debug("Found #{length(ex_files)} source files for transformation",
        sandbox_id: sandbox_id,
        files: ex_files
      )

      # Transform each file
      result =
        Enum.reduce_while(ex_files, {:ok, transformation_info}, fn file_path, {:ok, acc_info} ->
          case transform_source_file(
                 sandbox_id,
                 file_path,
                 table_prefixes,
                 namespace_prefix,
                 transform_modules
               ) do
            {:ok, file_mappings} ->
              updated_info = %{
                acc_info
                | module_mappings: Map.merge(acc_info.module_mappings, file_mappings),
                  transformed_files: [file_path | acc_info.transformed_files]
              }

              {:cont, {:ok, updated_info}}

            {:error, reason} ->
              {:halt, {:error, {:file_transformation_failed, file_path, reason}}}
          end
        end)

      case result do
        {:ok, final_info} ->
          Logger.info(
            "Successfully transformed #{length(final_info.transformed_files)} files for sandbox #{sandbox_id}",
            module_count: map_size(final_info.module_mappings)
          )

          {:ok, final_info}

        {:error, _} = error ->
          # Clean up partial transformation
          ModuleTransformer.destroy_module_registry(sandbox_id,
            table_prefix: table_prefixes.module_registry
          )

          error
      end
    rescue
      error ->
        ModuleTransformer.destroy_module_registry(sandbox_id,
          table_prefix: table_prefixes.module_registry
        )

        {:error, {:transformation_exception, error}}
    end
  end

  defp add_security_opts(compile_opts, security_profile) when is_map(security_profile) do
    restricted_modules = Map.get(security_profile, :restricted_modules, [])
    allowed_operations = Map.get(security_profile, :allowed_operations, [])

    security_scan =
      case {restricted_modules, allowed_operations} do
        {[], [:all]} -> false
        _ -> true
      end

    compile_opts
    |> Keyword.put(:restricted_modules, restricted_modules)
    |> Keyword.put(:allowed_operations, allowed_operations)
    |> Keyword.put(:security_scan, security_scan)
  end

  defp add_security_opts(compile_opts, _security_profile), do: compile_opts

  defp apply_resource_limits(compile_opts, limits) when is_map(limits) do
    compile_opts
    |> maybe_put(:memory_limit, Map.get(limits, :max_memory))
    |> maybe_put(:cpu_limit, Map.get(limits, :max_cpu_percentage))
    |> maybe_put(:max_processes, Map.get(limits, :max_processes))
  end

  defp apply_resource_limits(compile_opts, _limits), do: compile_opts

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp transform_source_file(
         sandbox_id,
         file_path,
         table_prefixes,
         namespace_prefix,
         transform_modules
       ) do
    # Read the source file
    case File.read(file_path) do
      {:ok, source_code} ->
        transform_and_write_source(
          sandbox_id,
          file_path,
          source_code,
          table_prefixes,
          namespace_prefix,
          transform_modules
        )

      {:error, read_error} ->
        {:error, {:read_failed, read_error}}
    end
  rescue
    error ->
      {:error, {:file_exception, error}}
  end

  defp transform_and_write_source(
         sandbox_id,
         file_path,
         source_code,
         table_prefixes,
         namespace_prefix,
         transform_modules
       ) do
    case ModuleTransformer.transform_source(source_code, sandbox_id,
           namespace_prefix: namespace_prefix,
           transform_modules: transform_modules
         ) do
      {:ok, transformed_code, module_mappings} ->
        write_transformed_source(
          sandbox_id,
          file_path,
          transformed_code,
          module_mappings,
          table_prefixes
        )

      {:error, transform_error} ->
        {:error, {:transform_failed, transform_error}}
    end
  end

  defp write_transformed_source(
         sandbox_id,
         file_path,
         transformed_code,
         module_mappings,
         table_prefixes
       ) do
    case File.write(file_path, transformed_code) do
      :ok ->
        # Register module mappings
        Enum.each(module_mappings, fn {original, transformed} ->
          ModuleTransformer.register_module_mapping(sandbox_id, original, transformed,
            table_prefix: table_prefixes.module_registry
          )
        end)

        {:ok, module_mappings}

      {:error, write_error} ->
        {:error, {:write_failed, write_error}}
    end
  end

  defp collect_transform_modules(ex_files) do
    Enum.reduce(ex_files, MapSet.new(), fn file_path, acc ->
      case File.read(file_path) do
        {:ok, source_code} ->
          case ModuleTransformer.extract_module_names(source_code) do
            {:ok, modules} ->
              Enum.reduce(modules, acc, fn module, set -> MapSet.put(set, module) end)

            {:error, _} ->
              acc
          end

        {:error, _} ->
          acc
      end
    end)
  end

  defp filter_source_files(ex_files, sandbox_path, opts) do
    exclude_dirs = Keyword.get(opts, :source_exclude_dirs, @default_source_exclude_dirs)

    if exclude_dirs == [] do
      ex_files
    else
      normalized_excludes = normalize_source_excludes(exclude_dirs, sandbox_path)

      ex_files
      |> Enum.reject(fn file_path -> path_excluded?(file_path, normalized_excludes) end)
    end
  end

  defp normalize_source_excludes(exclude_dirs, sandbox_path) do
    base = Path.expand(sandbox_path)

    exclude_dirs
    |> Enum.map(&to_string/1)
    |> Enum.map(fn dir ->
      if Path.type(dir) == :absolute do
        Path.expand(dir)
      else
        Path.expand(Path.join(base, dir))
      end
    end)
  end

  defp path_excluded?(path, exclude_dirs) do
    expanded = Path.expand(path)

    Enum.any?(exclude_dirs, fn excluded ->
      expanded == excluded or String.starts_with?(expanded, excluded <> "/")
    end)
  end

  defp maybe_add_source_files(compile_opts, %{source_files: source_files}) do
    Keyword.put(compile_opts, :source_files, source_files)
  end

  defp maybe_add_source_files(compile_opts, _), do: compile_opts

  defp maybe_ignore_consolidated_protocols(compile_opts, :reconsolidate) do
    Keyword.put(compile_opts, :ignore_already_consolidated, true)
  end

  defp maybe_ignore_consolidated_protocols(compile_opts, _), do: compile_opts

  defp load_sandbox_modules(sandbox_id, compile_info, services, table_prefixes) do
    compile_info.beam_files
    |> Enum.reduce_while(:ok, fn beam_file, :ok ->
      case load_beam_file(sandbox_id, beam_file, services, table_prefixes) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_reconsolidate_protocols(compile_info, opts) do
    case Keyword.get(opts, :protocol_consolidation, :reconsolidate) do
      :reconsolidate -> reconsolidate_protocols(compile_info)
      _ -> :ok
    end
  end

  defp reconsolidate_protocols(compile_info) do
    ebin_dirs =
      compile_info.beam_files
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    protocol_paths = protocol_search_paths(ebin_dirs)
    protocols = Protocol.extract_protocols(protocol_paths)

    Enum.each(protocols, fn protocol ->
      if Protocol.consolidated?(protocol) do
        sandbox_impls = Protocol.extract_impls(protocol, ebin_dirs)

        if sandbox_impls != [] do
          impls =
            Protocol.extract_impls(protocol, protocol_paths)
            |> Enum.uniq()

          case Protocol.consolidate(protocol, impls) do
            {:ok, binary} ->
              load_consolidated_protocol(protocol, binary)

            {:error, _reason} ->
              :ok
          end
        end
      end
    end)

    :ok
  end

  defp protocol_search_paths(ebin_dirs) do
    code_paths =
      :code.get_path()
      |> Enum.map(&to_string/1)
      |> Enum.filter(&File.dir?/1)

    Enum.uniq(code_paths ++ ebin_dirs)
  end

  defp load_consolidated_protocol(protocol, binary) do
    beam_path = :code.which(protocol)
    beam_path = if is_list(beam_path), do: beam_path, else: ~c"nofile"

    case :code.load_binary(protocol, beam_path, binary) do
      {:module, ^protocol} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to load consolidated protocol",
          protocol: protocol,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp load_beam_file(sandbox_id, beam_file, services, table_prefixes) do
    beam_data = File.read!(beam_file)
    module = extract_module_from_beam(beam_data)

    unless module do
      throw({:beam_info_failed, "Could not extract module name from BEAM file: #{beam_file}"})
    end

    with :ok <- load_module_binary(module, beam_data, beam_file),
         :ok <-
           load_virtual_module(
             sandbox_id,
             module,
             beam_data,
             table_prefixes.virtual_code
           ) do
      case register_module_version(
             sandbox_id,
             module,
             beam_data,
             services.module_version_manager
           ) do
        {:ok, version} ->
          Logger.debug("Loaded module #{module} version #{version} for sandbox #{sandbox_id}")
          :ok

        {:error, {:circular_dependency, deps}} ->
          if Config.module_version_debug_cycles?() do
            Logger.info("Skipping module version tracking due to circular deps",
              sandbox_id: sandbox_id,
              module: module,
              circular_dependencies: deps
            )
          end

          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:module_already_loaded, ^module}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:beam_load_failed, beam_file, error}}
  catch
    thrown_error ->
      {:error, thrown_error}
  end

  defp load_module_binary(module, beam_data, beam_file) do
    case :code.load_binary(module, to_charlist(beam_file), beam_data) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, {:load_failed, module, reason}}
    end
  rescue
    error ->
      {:error, {:load_failed, module, error}}
  end

  defp load_virtual_module(sandbox_id, module, beam_data, table_prefix) do
    case VirtualCodeTable.load_module(sandbox_id, module, beam_data, table_prefix: table_prefix) do
      :ok -> :ok
      {:error, {:module_already_loaded, ^module}} -> {:error, {:module_already_loaded, module}}
      {:error, reason} -> {:error, {:virtual_load_failed, module, reason}}
    end
  end

  defp register_module_version(sandbox_id, module, beam_data, server) do
    case ModuleVersionManager.register_module_version(sandbox_id, module, beam_data,
           server: server
         ) do
      {:ok, version} -> {:ok, version}
      {:error, {:circular_dependency, deps}} -> {:error, {:circular_dependency, deps}}
      {:error, reason} -> {:error, {:version_registration_failed, module, reason}}
    end
  end

  defp load_sandbox_application(app_name, _sandbox_id, _app_file) do
    case Application.load(app_name) do
      :ok ->
        :ok

      {:error, {:already_loaded, ^app_name}} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to load application #{app_name}: #{inspect(reason)}")
        {:error, {:load_failed, reason}}
    end
  end

  defp extract_module_from_beam(beam_data) do
    case :beam_lib.info(beam_data) do
      info when is_list(info) ->
        Keyword.get(info, :module)

      {:error, :beam_lib, _reason} ->
        nil
    end
  end

  defp namespace_prefix_from_opts(full_opts) do
    full_opts
    |> Keyword.get(:compile_info, %{})
    |> Map.get(:module_transformation, %{})
    |> Map.get(:namespace_prefix)
  end

  defp ensure_table(table_name, opts) do
    case :ets.whereis(table_name) do
      :undefined ->
        try do
          :ets.new(table_name, opts)
          Logger.info("Created ETS table #{table_name}")
        catch
          :error, :badarg ->
            Logger.debug("ETS table #{table_name} was created concurrently")
        end

      _ ->
        :ok
    end
  end

  defp split_server_opts(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_opts = Keyword.delete(opts, :server)
    {server, call_opts}
  end

  # Additional helper functions for comprehensive monitoring
end
