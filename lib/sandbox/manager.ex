defmodule Sandbox.Manager do
  @moduledoc """
  Manages the lifecycle of sandbox OTP applications with true hot-reload isolation.

  This manager provides a clean API for starting, stopping, and reconfiguring
  entire sandbox applications using isolated compilation and dynamic module loading.
  Features complete fault isolation and hot-reload capabilities.
  """

  use GenServer
  require Logger

  alias Sandbox.IsolatedCompiler
  alias Sandbox.ModuleVersionManager

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new sandbox with the specified ID and configuration.
  
  ## Examples
  
      iex> create_sandbox("my-sandbox", MyApp.Supervisor)
      {:ok, %{id: "my-sandbox", ...}}
      
      iex> create_sandbox("test-sandbox", :my_app, supervisor_module: MyApp.Supervisor)
      {:ok, %{id: "test-sandbox", ...}}
  """
  def create_sandbox(sandbox_id, module_or_app, opts \\ []) do
    GenServer.call(__MODULE__, {:create_sandbox, sandbox_id, module_or_app, opts})
  end

  @doc """
  Destroys a sandbox and cleans up all resources.
  """
  def destroy_sandbox(sandbox_id) do
    GenServer.call(__MODULE__, {:destroy_sandbox, sandbox_id})
  end

  @doc """
  Restarts a sandbox with the same configuration.
  """
  def restart_sandbox(sandbox_id) do
    GenServer.call(__MODULE__, {:restart_sandbox, sandbox_id})
  end

  @doc """
  Hot-reloads a sandbox with new code.
  """
  def hot_reload_sandbox(sandbox_id, new_beam_data) do
    GenServer.call(__MODULE__, {:hot_reload_sandbox, sandbox_id, new_beam_data}, 30_000)
  end

  @doc """
  Gets information about a specific sandbox.
  """
  def get_sandbox_info(sandbox_id) do
    GenServer.call(__MODULE__, {:get_sandbox_info, sandbox_id})
  end

  @doc """
  Lists all active sandboxes.
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
    # Use ETS table for fast sandbox lookup
    case :ets.info(:sandboxes) do
      :undefined ->
        :ets.new(:sandboxes, [:named_table, :set, :protected])
        Logger.info("Created new ETS table :sandboxes")

      _ ->
        Logger.info("ETS table :sandboxes already exists, clearing it")
        :ets.delete_all_objects(:sandboxes)
    end

    state = %{
      sandboxes: %{},
      next_id: 1,
      sandbox_code_paths: %{},
      compilation_artifacts: %{}
    }

    Logger.info("Sandbox.Manager started")
    {:ok, state}
  end

  @impl true
  def handle_call({:create_sandbox, sandbox_id, module_or_app, opts}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      nil ->
        # Determine if we're dealing with a supervisor module or application
        {app_name, supervisor_module} = parse_module_or_app(module_or_app, opts)

        # Create new sandbox application
        case start_sandbox_application(sandbox_id, app_name, supervisor_module, opts) do
          {:ok, app_pid, supervisor_pid, full_opts} ->
            sandbox_info = %{
              id: sandbox_id,
              app_name: app_name,
              supervisor_module: supervisor_module,
              app_pid: app_pid,
              supervisor_pid: supervisor_pid,
              opts: full_opts,
              created_at: System.system_time(:millisecond),
              restart_count: 0,
              status: :running
            }

            # Monitor the application
            ref = Process.monitor(app_pid)

            # Store in ETS for fast lookup
            :ets.insert(:sandboxes, {sandbox_id, sandbox_info})

            new_sandboxes = Map.put(state.sandboxes, sandbox_id, {sandbox_info, ref})

            Logger.info(
              "Created sandbox #{sandbox_id} with app #{app_name} PID #{inspect(app_pid)}"
            )

            {:reply, {:ok, sandbox_info}, %{state | sandboxes: new_sandboxes}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {existing_info, _ref} ->
        {:reply, {:error, {:already_exists, existing_info}}, state}
    end
  end

  @impl true
  def handle_call({:destroy_sandbox, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_info, ref} ->
        # Stop monitoring
        Process.demonitor(ref, [:flush])

        # Remove from state and ETS BEFORE stopping application
        :ets.delete(:sandboxes, sandbox_id)
        new_sandboxes = Map.delete(state.sandboxes, sandbox_id)

        # Clean up module versions
        ModuleVersionManager.cleanup_sandbox_modules(sandbox_id)

        # Now stop the application gracefully
        :ok = stop_sandbox_application(sandbox_info.app_name, sandbox_id)

        # Terminate the supervisor if it's still alive
        if Process.alive?(sandbox_info.supervisor_pid) do
          terminate_supervisor(sandbox_info.supervisor_pid)
        end

        Logger.info("Destroyed sandbox #{sandbox_id}")
        {:reply, :ok, %{state | sandboxes: new_sandboxes}}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:restart_sandbox, sandbox_id}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_info, ref} ->
        # Stop current application
        Process.demonitor(ref, [:flush])
        stop_sandbox_application(sandbox_info.app_name, sandbox_id)

        # Start new application with same configuration
        case start_sandbox_application(
               sandbox_id,
               sandbox_info.app_name,
               sandbox_info.supervisor_module,
               sandbox_info.opts
             ) do
          {:ok, new_app_pid, new_supervisor_pid, _opts} ->
            # Update sandbox info
            updated_info = %{
              sandbox_info
              | app_pid: new_app_pid,
                supervisor_pid: new_supervisor_pid,
                restart_count: sandbox_info.restart_count + 1
            }

            # Monitor new application
            new_ref = Process.monitor(new_app_pid)

            # Update state and ETS
            :ets.insert(:sandboxes, {sandbox_id, updated_info})
            new_sandboxes = Map.put(state.sandboxes, sandbox_id, {updated_info, new_ref})

            Logger.info(
              "Restarted sandbox #{sandbox_id} with new app PID #{inspect(new_app_pid)}"
            )

            {:reply, {:ok, updated_info}, %{state | sandboxes: new_sandboxes}}

          {:error, reason} ->
            # Remove failed sandbox
            :ets.delete(:sandboxes, sandbox_id)
            new_sandboxes = Map.delete(state.sandboxes, sandbox_id)
            {:reply, {:error, reason}, %{state | sandboxes: new_sandboxes}}
        end

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:hot_reload_sandbox, sandbox_id, new_beam_data}, _from, state) do
    case Map.get(state.sandboxes, sandbox_id) do
      {sandbox_info, _ref} ->
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
    case :ets.lookup(:sandboxes, sandbox_id) do
      [{^sandbox_id, sandbox_info}] ->
        {:reply, {:ok, sandbox_info}, state}

      [] ->
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
    sandboxes = :ets.tab2list(:sandboxes)
    sandbox_list = Enum.map(sandboxes, fn {_id, info} -> info end)
    {:reply, sandbox_list, state}
  end

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    Logger.info(
      "Sandbox.Manager received DOWN message for #{inspect(pid)} with reason #{inspect(reason)}"
    )

    try do
      # Find which sandbox died
      case find_sandbox_by_ref(state.sandboxes, ref) do
        {sandbox_id, _sandbox_info} ->
          Logger.warning("Sandbox #{sandbox_id} supervisor died: #{inspect(reason)}")

          # Remove from state and ETS
          try do
            :ets.delete(:sandboxes, sandbox_id)
          rescue
            error ->
              Logger.error("Error deleting from ETS: #{inspect(error)}")
          end

          new_sandboxes = Map.delete(state.sandboxes, sandbox_id)

          Logger.info("Successfully cleaned up sandbox #{sandbox_id}")
          {:noreply, %{state | sandboxes: new_sandboxes}}

        nil ->
          Logger.warning("Received DOWN message for unknown process #{inspect(pid)}")
          {:noreply, state}
      end
    rescue
      error ->
        Logger.error("Error in handle_info: #{inspect(error)}")
        {:noreply, state}
    end
  end

  # Private Functions

  defp terminate_supervisor(supervisor_pid) do
    Task.start(fn ->
      if Process.alive?(supervisor_pid) do
        supervisor_ref = Process.monitor(supervisor_pid)
        Process.exit(supervisor_pid, :shutdown)

        receive do
          {:DOWN, ^supervisor_ref, :process, ^supervisor_pid, _reason} ->
            :ok
        after
          2000 ->
            Process.demonitor(supervisor_ref, [:flush])
            :ok
        end
      end
    end)
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
    sandbox_path = Keyword.get(opts, :sandbox_path, default_sandbox_path(app_name))

    # Compile sandbox application in isolation
    with {:ok, compile_info} <-
           compile_sandbox_isolated(sandbox_id, sandbox_path, app_name, opts),
         :ok <- setup_code_paths(sandbox_id, compile_info),
         :ok <- load_sandbox_modules(sandbox_id, compile_info),
         :ok <- load_sandbox_application(app_name, sandbox_id, compile_info.app_file),
         {:ok, app_pid, supervisor_pid} <-
           start_application_and_supervisor(sandbox_id, app_name, supervisor_module, opts) do
      {:ok, app_pid, supervisor_pid, Keyword.put(opts, :compile_info, compile_info)}
    else
      {:error, reason} ->
        Logger.error("Failed to start sandbox application #{app_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp default_sandbox_path(app_name) do
    # Default to a examples directory or current directory
    Path.join([File.cwd!(), "sandboxes", to_string(app_name)])
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

          {:ok, info} ->
            info[:module]

          {:error, reason} ->
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

  defp find_sandbox_by_ref(sandboxes, target_ref) do
    try do
      Enum.find_value(sandboxes, fn {sandbox_id, {sandbox_info, ref}} ->
        if ref == target_ref do
          {sandbox_id, sandbox_info}
        else
          nil
        end
      end)
    rescue
      error ->
        Logger.error("Error in find_sandbox_by_ref: #{inspect(error)}")
        nil
    end
  end

  defp extract_module_from_beam(beam_data) do
    case :beam_lib.info(beam_data) do
      info when is_list(info) ->
        Keyword.get(info, :module)

      {:ok, info} ->
        info[:module]

      _ ->
        nil
    end
  end
end