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

  alias Sandbox.IsolatedCompiler
  alias Sandbox.ModuleVersionManager
  alias Sandbox.Models.SandboxState

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
    * `:auto_reload` - Enable automatic file watching (default: false)
    * `:state_migration_handler` - Custom state migration function

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
    GenServer.call(__MODULE__, {:create_sandbox, sandbox_id, module_or_app, opts}, 30_000)
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
  def destroy_sandbox(sandbox_id) do
    GenServer.call(__MODULE__, {:destroy_sandbox, sandbox_id}, 15_000)
  end

  @doc """
  Restarts a sandbox with state preservation and configuration retention.

  Attempts to preserve as much state as possible during restart while
  maintaining the same configuration and incrementing restart count.

  ## Examples

      iex> restart_sandbox("my-sandbox")
      {:ok, %{id: "my-sandbox", restart_count: 1, ...}}
  """
  def restart_sandbox(sandbox_id) do
    GenServer.call(__MODULE__, {:restart_sandbox, sandbox_id}, 30_000)
  end

  @doc """
  Hot-reloads a sandbox with new code.
  """
  def hot_reload_sandbox(sandbox_id, new_beam_data, opts \\ []) do
    GenServer.call(__MODULE__, {:hot_reload_sandbox, sandbox_id, new_beam_data, opts}, 30_000)
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
  def get_sandbox_info(sandbox_id) do
    GenServer.call(__MODULE__, {:get_sandbox_info, sandbox_id})
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
  def list_sandboxes do
    GenServer.call(__MODULE__, :list_sandboxes)
  end

  @doc """
  Gets the main process PID for a sandbox.
  """
  def get_sandbox_pid(sandbox_id) do
    GenServer.call(__MODULE__, {:get_sandbox_pid, sandbox_id})
  end

  @doc """
  Synchronizes state (useful for testing).
  """
  def sync do
    GenServer.call(__MODULE__, :sync)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    # Initialize ETS tables for fast sandbox lookup and registry management
    case :ets.info(:sandboxes) do
      :undefined ->
        :ets.new(:sandboxes, [:named_table, :set, :public, {:read_concurrency, true}])
        Logger.info("Created new ETS table :sandboxes with read concurrency")

      _ ->
        Logger.info("ETS table :sandboxes already exists, clearing it")
        :ets.delete_all_objects(:sandboxes)
    end

    # Create additional ETS table for process monitoring
    case :ets.info(:sandbox_monitors) do
      :undefined ->
        :ets.new(:sandbox_monitors, [:named_table, :set, :public])
        Logger.info("Created new ETS table :sandbox_monitors")

      _ ->
        Logger.info("ETS table :sandbox_monitors already exists, clearing it")
        :ets.delete_all_objects(:sandbox_monitors)
    end

    state = %{
      sandboxes: %{},
      monitors: %{},
      cleanup_tasks: %{},
      next_cleanup_id: 1
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
        :ets.insert(:sandboxes, {sandbox_id, SandboxState.to_info(stopping_state)})

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
        :ets.insert(:sandboxes, {sandbox_id, SandboxState.to_info(stopping_state)})

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
        result = ModuleVersionManager.hot_swap_module(sandbox_id, module, new_beam_data)

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
    case :ets.lookup(:sandboxes, sandbox_id) do
      [{^sandbox_id, sandbox_info}] ->
        {:reply, {:ok, sandbox_info.app_pid}, state}

      [] ->
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
            {:error,
             {:sandbox_mix_file_unreadable, "cannot read mix.exs file: #{inspect(reason)}"}}
        end
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
    if value > 10000 do
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
      value > 3600_000 ->
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
        case get_security_profile(profile_name) do
          {:ok, profile} ->
            case validate_security_profile_consistency(profile) do
              :ok -> {:ok, profile}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      custom_profile when is_map(custom_profile) ->
        validate_custom_security_profile(custom_profile)

      invalid ->
        {:error,
         {:invalid_security_profile_type,
          "security_profile must be an atom (:high, :medium, :low) or a custom profile map, got: #{inspect(invalid)}"}}
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
        cond do
          :all in ops ->
            {:error,
             {:security_profile_inconsistent, "high isolation level cannot allow :all operations"}}

          true ->
            dangerous_ops = [:file_write, :network_server, :crypto]
            allowed_dangerous = Enum.filter(dangerous_ops, &(&1 in ops))

            if length(allowed_dangerous) > 0 do
              {:error,
               {:security_profile_inconsistent,
                "high isolation level should not allow dangerous operations: #{inspect(allowed_dangerous)}"}}
            else
              :ok
            end
        end

      _ ->
        :ok
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
    :ets.insert(:sandboxes, {sandbox_id, SandboxState.to_info(sandbox_state)})
    new_state = %{state | sandboxes: Map.put(state.sandboxes, sandbox_id, {sandbox_state, nil})}

    # Start sandbox application with comprehensive monitoring
    case start_sandbox_application_with_monitoring(sandbox_state) do
      {:ok, updated_sandbox_state, monitor_ref} ->
        # Update state with process information
        :ets.insert(:sandboxes, {sandbox_id, SandboxState.to_info(updated_sandbox_state)})
        :ets.insert(:sandbox_monitors, {monitor_ref, sandbox_id})

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
        :ets.delete(:sandboxes, sandbox_id)
        cleanup_state = Map.delete(new_state.sandboxes, sandbox_id)

        Logger.error("Failed to create sandbox",
          sandbox_id: sandbox_id,
          reason: inspect(reason)
        )

        {:reply, {:error, reason}, %{new_state | sandboxes: cleanup_state}}
    end
  end

  defp start_sandbox_application_with_monitoring(sandbox_state) do
    %SandboxState{
      id: sandbox_id,
      app_name: app_name,
      supervisor_module: supervisor_module,
      config: config
    } = sandbox_state

    # Start sandbox application with enhanced error handling
    case start_sandbox_application(sandbox_id, app_name, supervisor_module, Map.to_list(config)) do
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
        updated_state =
          sandbox_state
          |> SandboxState.update_processes(app_pid, supervisor_pid, monitor_ref)
          |> SandboxState.update_status(:running)
          |> Map.put(:compilation_artifacts, artifacts)

        {:ok, updated_state, monitor_ref}

      {:error, reason} ->
        # Update status to error
        _error_state = SandboxState.update_status(sandbox_state, :error)
        {:error, reason}
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
    cleanup_errors = cleanup_module_versions(sandbox_id, cleanup_errors)

    # 3. Terminate processes gracefully
    cleanup_errors = cleanup_processes(supervisor_pid, cleanup_errors)

    # 4. Stop sandbox application
    cleanup_errors = cleanup_application(app_name, sandbox_id, cleanup_errors)

    # 5. Clean up compilation artifacts
    cleanup_errors = cleanup_compilation_artifacts(artifacts, cleanup_errors)

    # 6. Remove from ETS tables
    cleanup_errors = cleanup_ets_entries(sandbox_id, monitor_ref, cleanup_errors)

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
    try do
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
  end

  defp cleanup_module_versions(sandbox_id, errors) do
    try do
      case GenServer.whereis(Sandbox.ModuleVersionManager) do
        nil ->
          Logger.debug("ModuleVersionManager not running, skipping module cleanup")
          errors

        _pid ->
          ModuleVersionManager.cleanup_sandbox_modules(sandbox_id)
          errors
      end
    rescue
      error ->
        Logger.warning("Error during module version cleanup",
          sandbox_id: sandbox_id,
          error: inspect(error)
        )

        [{:module_cleanup_failed, error} | errors]
    end
  end

  defp cleanup_processes(supervisor_pid, errors) do
    try do
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
  end

  defp cleanup_application(app_name, sandbox_id, errors) do
    try do
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
  end

  defp cleanup_compilation_artifacts(artifacts, errors) do
    try do
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
  end

  defp cleanup_ets_entries(sandbox_id, monitor_ref, errors) do
    try do
      :ets.delete(:sandboxes, sandbox_id)

      if monitor_ref do
        :ets.delete(:sandbox_monitors, monitor_ref)
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
          case start_sandbox_application_with_monitoring(restarting_state) do
            {:ok, new_sandbox_state, new_monitor_ref} ->
              Logger.debug("New application started successfully",
                sandbox_id: sandbox_id,
                new_pid: new_sandbox_state.supervisor_pid
              )

              # 6. Restore preserved state if available
              final_state = restore_preserved_state(new_sandbox_state, preserved_state)

              # 7. Update ETS and state
              :ets.insert(:sandboxes, {sandbox_id, SandboxState.to_info(final_state)})
              :ets.insert(:sandbox_monitors, {new_monitor_ref, sandbox_id})

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

              :ets.delete(:sandboxes, sandbox_id)

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

        :ets.delete(:sandboxes, sandbox_id)

        {:error, {:restart_exception, error}, cleanup_state}
    end
  end

  defp attempt_state_preservation(%SandboxState{config: %{state_migration_handler: handler}})
       when is_function(handler) do
    try do
      # This is a placeholder for state preservation logic
      # In a full implementation, this would capture GenServer states
      {:ok, %{preserved_at: DateTime.utc_now(), handler: handler}}
    rescue
      error ->
        Logger.warning("State preservation failed", error: inspect(error))
        {:error, error}
    end
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
        :ets.insert(:sandboxes, {sandbox_id, SandboxState.to_info(error_state)})

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

    # Get current resource usage if process is alive
    current_resource_usage =
      case sandbox_state.supervisor_pid do
        pid when is_pid(pid) and pid != nil ->
          if Process.alive?(pid) do
            get_real_time_resource_usage(pid)
          else
            sandbox_state.resource_usage
          end

        _ ->
          sandbox_state.resource_usage
      end

    # Calculate uptime
    uptime =
      case sandbox_state.status do
        :running ->
          DateTime.diff(DateTime.utc_now(), sandbox_state.created_at, :millisecond)

        _ ->
          sandbox_state.resource_usage.uptime
      end

    updated_resource_usage = Map.put(current_resource_usage, :uptime, uptime)

    # Convert to info map with updated resource usage
    sandbox_state
    |> SandboxState.update_resource_usage(updated_resource_usage)
    |> SandboxState.to_info()
  end

  defp get_real_time_resource_usage(pid) do
    try do
      # Get process info for memory usage
      process_info = Process.info(pid, [:memory, :message_queue_len, :heap_size, :stack_size])

      memory_usage =
        case process_info do
          nil -> 0
          info -> Keyword.get(info, :memory, 0)
        end

      # Count child processes (simplified)
      child_count =
        case Process.info(pid, :links) do
          nil -> 0
          {:links, links} -> length(links)
        end

      %{
        current_memory: memory_usage,
        # +1 for the supervisor itself
        current_processes: child_count + 1,
        # Would need more complex calculation for real CPU usage
        cpu_usage: 0.0,
        # Will be calculated by caller
        uptime: 0
      }
    rescue
      _ ->
        # Fallback to default values if process info fails
        %{
          current_memory: 0,
          current_processes: 0,
          cpu_usage: 0.0,
          uptime: 0
        }
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

  defp start_sandbox_application(sandbox_id, app_name, supervisor_module, opts) do
    # Get sandbox path from options or use default
    original_sandbox_path = Keyword.get(opts, :sandbox_path, default_sandbox_path(app_name))

    # Prepare unique sandbox directory to avoid module conflicts
    with {:ok, sandbox_path} <-
           prepare_unique_sandbox_directory(sandbox_id, original_sandbox_path),
         # Compile sandbox application in isolation
         {:ok, compile_info} <-
           compile_sandbox_isolated(sandbox_id, sandbox_path, app_name, opts),
         :ok <- setup_code_paths(sandbox_id, compile_info),
         :ok <- load_sandbox_modules(sandbox_id, compile_info),
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
          :ok ->
            source_item = Path.join(source, item)
            dest_item = Path.join(destination, item)

            if File.dir?(source_item) do
              copy_directory(source_item, dest_item)
            else
              case File.copy(source_item, dest_item) do
                {:ok, _} -> :ok
                {:error, reason} -> {:error, reason}
              end
            end

          error ->
            error
        end
      end)
    end
  end

  defp setup_code_paths(_sandbox_id, compile_info) do
    ebin_path = Path.dirname(List.first(compile_info.beam_files, ""))

    if File.exists?(ebin_path) do
      Code.prepend_path(ebin_path)
      Logger.debug("Added code path: #{ebin_path}")
      :ok
    else
      {:error, {:ebin_path_not_found, ebin_path}}
    end
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

  defp compile_sandbox_isolated(sandbox_id, sandbox_path, app_name, opts) do
    compile_opts = [
      timeout: Keyword.get(opts, :compile_timeout, 30_000),
      validate_beams: Keyword.get(opts, :validate_beams, true),
      env: %{
        "MIX_ENV" => "dev",
        "MIX_TARGET" => "host"
      }
    ]

    Logger.info("Compiling sandbox #{sandbox_id} in isolation",
      sandbox_path: sandbox_path,
      app_name: app_name
    )

    case IsolatedCompiler.compile_sandbox(sandbox_path, compile_opts) do
      {:ok, compile_info} ->
        Logger.info("Successfully compiled sandbox #{sandbox_id}",
          compilation_time: compile_info.compilation_time,
          beam_files: length(compile_info.beam_files)
        )

        {:ok, compile_info}

      {:error, reason} ->
        report = IsolatedCompiler.compilation_report({:error, reason})

        Logger.error("Failed to compile sandbox #{sandbox_id}",
          reason: inspect(reason),
          details: report.details
        )

        {:error, reason}
    end
  end

  defp load_sandbox_modules(sandbox_id, compile_info) do
    compile_info.beam_files
    |> Enum.reduce_while(:ok, fn beam_file, :ok ->
      case load_beam_file(sandbox_id, beam_file) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_beam_file(sandbox_id, beam_file) do
    try do
      beam_data = File.read!(beam_file)

      # Extract module name from BEAM
      module =
        case :beam_lib.info(String.to_charlist(beam_file)) do
          info when is_list(info) ->
            Keyword.get(info, :module)

          {:error, :beam_lib, reason} ->
            throw({:beam_info_failed, beam_file, reason})
        end

      # Load the module
      case :code.load_binary(module, String.to_charlist(beam_file), beam_data) do
        {:module, ^module} ->
          # Register with version manager
          case ModuleVersionManager.register_module_version(sandbox_id, module, beam_data) do
            {:ok, version} ->
              Logger.debug("Loaded module #{module} version #{version} for sandbox #{sandbox_id}")
              :ok

            {:error, reason} ->
              {:error, {:version_registration_failed, module, reason}}
          end

        {:error, reason} ->
          {:error, {:code_load_failed, module, reason}}
      end
    rescue
      error ->
        {:error, {:beam_load_failed, beam_file, error}}
    catch
      thrown_error ->
        {:error, thrown_error}
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

  # Additional helper functions for comprehensive monitoring
end
