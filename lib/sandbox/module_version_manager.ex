defmodule Sandbox.ModuleVersionManager do
  @moduledoc """
  Tracks module versions and handles hot-swapping for sandbox applications.

  This module provides version management for dynamically loaded modules,
  enabling safe hot-swapping with rollback capabilities and dependency
  tracking to ensure proper reload ordering.
  """

  use GenServer
  require Logger

  alias Sandbox.Config

  @max_versions_per_module 10

  @type module_version :: %{
          sandbox_id: String.t(),
          module: atom(),
          version: non_neg_integer(),
          beam_data: binary(),
          loaded_at: DateTime.t(),
          dependencies: [atom()],
          checksum: String.t()
        }

  @type hot_swap_result ::
          {:ok, :hot_swapped}
          | {:ok, :no_change}
          | {:error, :module_not_found}
          | {:error, :same_version}
          | {:error, {:swap_failed, reason :: any()}}
          | {:error, {:state_migration_failed, reason :: any()}}

  # Client API

  @doc """
  Starts the ModuleVersionManager.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a new module version for a sandbox.
  """
  @spec register_module_version(String.t(), atom(), binary(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, any()}
  def register_module_version(sandbox_id, module, beam_data, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:register_module_version, sandbox_id, module, beam_data})
  end

  @doc """
  Hot-swaps a module with state preservation for GenServers.

  ## Options
    * `:state_handler` - Function to handle state migration `(old_state, old_version, new_version) -> new_state`
    * `:suspend_timeout` - Timeout for suspending processes (default: 5000ms)
  """
  @spec hot_swap_module(String.t(), atom(), binary(), keyword()) :: hot_swap_result()
  def hot_swap_module(sandbox_id, module, new_beam_data, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)

    GenServer.call(
      server,
      {:hot_swap_module, sandbox_id, module, new_beam_data, call_opts},
      30_000
    )
  end

  @doc """
  Rolls back a module to a previous version.
  """
  @spec rollback_module(String.t(), atom(), non_neg_integer(), keyword()) ::
          {:ok, :rolled_back} | {:error, any()}
  def rollback_module(sandbox_id, module, target_version, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:rollback_module, sandbox_id, module, target_version})
  end

  @doc """
  Gets the current version number for a module.
  """
  @spec get_current_version(String.t(), atom(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def get_current_version(sandbox_id, module, opts \\ []) do
    table_name = table_name_for_opts(opts)

    case :ets.lookup(table_name, {sandbox_id, module}) do
      [] ->
        {:error, :not_found}

      versions ->
        max_version =
          versions |> Enum.map(fn {_key, version_data} -> version_data.version end) |> Enum.max()

        {:ok, max_version}
    end
  end

  @doc """
  Gets module dependency graph for reload ordering.
  """
  @spec get_module_dependencies([atom()], keyword()) :: %{atom() => [atom()]}
  def get_module_dependencies(modules, opts \\ []) when is_list(modules) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:get_module_dependencies, modules, call_opts})
  end

  @doc """
  Calculates optimal reload order for modules based on dependencies.
  """
  @spec calculate_reload_order([atom()], keyword()) ::
          {:ok, [atom()]} | {:error, :circular_dependency}
  def calculate_reload_order(modules, opts \\ []) when is_list(modules) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:calculate_reload_order, modules, call_opts})
  end

  @doc """
  Performs cascading reload of modules in dependency order.
  """
  @spec cascading_reload(String.t(), [atom()], keyword()) ::
          {:ok, :reloaded} | {:error, any()}
  def cascading_reload(sandbox_id, modules, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:cascading_reload, sandbox_id, modules, call_opts}, 60_000)
  end

  @doc """
  Extracts dependencies from BEAM file with detailed analysis.
  """
  @spec extract_beam_dependencies(binary(), keyword()) ::
          {:ok, %{imports: [atom()], exports: [atom()], attributes: map()}} | {:error, any()}
  def extract_beam_dependencies(beam_data, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:extract_beam_dependencies, beam_data})
  end

  @doc """
  Detects circular dependencies in a module graph.
  """
  @spec detect_circular_dependencies(%{atom() => [atom()]}, keyword()) ::
          {:ok, :no_cycles} | {:error, {:circular_dependency, [atom()]}}
  def detect_circular_dependencies(dependency_graph, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:detect_circular_dependencies, dependency_graph})
  end

  @doc """
  Performs parallel reload of independent modules.
  """
  @spec parallel_reload(String.t(), [atom()], keyword()) ::
          {:ok, :reloaded} | {:error, any()}
  def parallel_reload(sandbox_id, modules, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:parallel_reload, sandbox_id, modules, call_opts}, 60_000)
  end

  @doc """
  Lists all versions for a specific module in a sandbox.
  """
  @spec list_module_versions(String.t(), atom(), keyword()) :: [module_version()]
  def list_module_versions(sandbox_id, module, opts \\ []) do
    table_name = table_name_for_opts(opts)

    :ets.lookup(table_name, {sandbox_id, module})
    |> Enum.map(fn {_key, version_data} -> version_data end)
    |> Enum.sort_by(& &1.version, :desc)
  end

  @doc """
  Gets version history for a module with statistics.
  """
  @spec get_version_history(String.t(), atom(), keyword()) :: %{
          current_version: non_neg_integer() | nil,
          total_versions: non_neg_integer(),
          versions: [module_version()]
        }
  def get_version_history(sandbox_id, module, opts \\ []) do
    versions = list_module_versions(sandbox_id, module, opts)

    %{
      current_version: if(versions == [], do: nil, else: hd(versions).version),
      total_versions: length(versions),
      versions: versions
    }
  end

  @doc """
  Cleans up all module versions for a sandbox.
  """
  @spec cleanup_sandbox_modules(String.t(), keyword()) :: :ok
  def cleanup_sandbox_modules(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:cleanup_sandbox_modules, sandbox_id})
  end

  @doc """
  Exports module versions for backup or migration.
  """
  @spec export_sandbox_modules(String.t(), keyword()) :: {:ok, map()} | {:error, any()}
  def export_sandbox_modules(sandbox_id, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:export_sandbox_modules, sandbox_id})
  end

  @doc """
  Gets the ETS table name for testing purposes.
  """
  @spec get_table_name(keyword()) :: atom()
  def get_table_name(opts \\ []) do
    table_name_for_opts(opts)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    table_name = resolve_table_name(opts)
    ensure_table(table_name)
    register_table_name(self(), table_name)

    if name = Keyword.get(opts, :name) do
      register_table_name(name, table_name)
    end

    Logger.info("Sandbox.ModuleVersionManager started with ETS table: #{table_name}")

    {:ok, %{table: table_name}}
  end

  @impl true
  def handle_call({:register_module_version, sandbox_id, module, beam_data}, _from, state) do
    result = do_register_module_version(state.table, sandbox_id, module, beam_data)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:hot_swap_module, sandbox_id, module, new_beam_data, opts}, _from, state) do
    result = do_hot_swap_module(state.table, sandbox_id, module, new_beam_data, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:rollback_module, sandbox_id, module, target_version}, _from, state) do
    result = do_rollback_module(state.table, sandbox_id, module, target_version)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_module_dependencies, modules, opts}, _from, state) do
    result = do_get_module_dependencies(state.table, modules, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:cleanup_sandbox_modules, sandbox_id}, _from, state) do
    result = do_cleanup_sandbox_modules(state.table, sandbox_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:export_sandbox_modules, sandbox_id}, _from, state) do
    result = do_export_sandbox_modules(state.table, sandbox_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:calculate_reload_order, modules, opts}, _from, state) do
    result = do_calculate_reload_order(state.table, modules, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:cascading_reload, sandbox_id, modules, opts}, _from, state) do
    result = do_cascading_reload(state.table, sandbox_id, modules, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:extract_beam_dependencies, beam_data}, _from, state) do
    result = do_extract_beam_dependencies(beam_data)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:detect_circular_dependencies, dependency_graph}, _from, state) do
    result = do_detect_circular_dependencies(dependency_graph)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:parallel_reload, sandbox_id, modules, opts}, _from, state) do
    result = do_parallel_reload(state.table, sandbox_id, modules, opts)
    {:reply, result, state}
  end

  # Private implementation functions

  defp do_register_module_version(table_name, sandbox_id, module, beam_data) do
    checksum = calculate_checksum(beam_data)

    # Check if this exact version already exists (checksum-based deduplication)
    existing_versions = :ets.lookup(table_name, {sandbox_id, module})

    case Enum.find(existing_versions, fn {_key, version_data} ->
           version_data.checksum == checksum
         end) do
      nil ->
        register_new_module_version(
          table_name,
          sandbox_id,
          module,
          beam_data,
          checksum,
          existing_versions
        )

      {_key, existing} ->
        # Same checksum - return existing version (deduplication)
        Logger.debug("Module version already exists, returning existing",
          sandbox_id: sandbox_id,
          module: module,
          version: existing.version,
          checksum: checksum
        )

        {:ok, existing.version}
    end
  end

  defp register_new_module_version(
         table_name,
         sandbox_id,
         module,
         beam_data,
         checksum,
         existing_versions
       ) do
    # New version - calculate next version number
    next_version = calculate_next_version(existing_versions)

    # Extract dependencies from BEAM with enhanced analysis
    case do_extract_beam_dependencies(beam_data) do
      {:ok, dependency_info} ->
        insert_module_version(
          table_name,
          sandbox_id,
          module,
          beam_data,
          checksum,
          next_version,
          dependency_info
        )

      {:error, reason} ->
        Logger.error("Failed to extract dependencies during registration",
          sandbox_id: sandbox_id,
          module: module,
          reason: reason
        )

        {:error, {:dependency_extraction_failed, reason}}
    end
  end

  defp calculate_next_version([]), do: 1

  defp calculate_next_version(versions) do
    versions
    |> Enum.map(fn {_key, version_data} -> version_data.version end)
    |> Enum.max()
    |> Kernel.+(1)
  end

  defp insert_module_version(
         table_name,
         sandbox_id,
         module,
         beam_data,
         checksum,
         next_version,
         dependency_info
       ) do
    dependencies = dependency_info.filtered_imports

    # Check for circular dependencies with existing modules
    case validate_no_circular_dependencies(table_name, sandbox_id, module, dependencies) do
      :ok ->
        module_version = %{
          sandbox_id: sandbox_id,
          module: module,
          version: next_version,
          beam_data: beam_data,
          loaded_at: DateTime.utc_now(),
          dependencies: dependencies,
          checksum: checksum,
          dependency_info: dependency_info
        }

        # Insert new version
        :ets.insert(table_name, {{sandbox_id, module}, module_version})

        # Clean up old versions if we exceed the limit
        cleanup_old_versions(table_name, sandbox_id, module)

        Logger.info("Registered module version with enhanced tracking",
          sandbox_id: sandbox_id,
          module: module,
          version: next_version,
          dependencies: length(dependencies),
          imports: length(dependency_info.imports),
          exports: length(dependency_info.exports)
        )

        {:ok, next_version}

      {:error, circular_deps} ->
        Logger.error("Circular dependency detected during registration",
          sandbox_id: sandbox_id,
          module: module,
          circular_dependencies: circular_deps
        )

        {:error, {:circular_dependency, circular_deps}}
    end
  end

  defp do_hot_swap_module(table_name, sandbox_id, module, new_beam_data, opts) do
    checksum = calculate_checksum(new_beam_data)

    # Check current version
    case get_current_module_version(table_name, sandbox_id, module) do
      nil ->
        {:error, :module_not_found}

      {_key, current_version} ->
        if current_version.checksum == checksum do
          {:ok, :no_change}
        else
          perform_hot_swap(table_name, sandbox_id, module, current_version, new_beam_data, opts)
        end
    end
  end

  defp perform_hot_swap(table_name, sandbox_id, module, current_version, new_beam_data, opts) do
    # Check if we should coordinate with dependent modules
    coordinate_dependencies = Keyword.get(opts, :coordinate_dependencies, true)

    if coordinate_dependencies do
      perform_coordinated_hot_swap(
        table_name,
        sandbox_id,
        module,
        current_version,
        new_beam_data,
        opts
      )
    else
      perform_simple_hot_swap(
        table_name,
        sandbox_id,
        module,
        current_version,
        new_beam_data,
        opts
      )
    end
  rescue
    error ->
      {:error, {:swap_failed, error}}
  end

  defp perform_coordinated_hot_swap(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         opts
       ) do
    # Find modules that depend on this module
    dependent_modules = find_dependent_modules(table_name, sandbox_id, module)

    if dependent_modules != [] do
      perform_hot_swap_with_dependents(
        table_name,
        sandbox_id,
        module,
        current_version,
        new_beam_data,
        opts,
        dependent_modules
      )
    else
      # No dependent modules, perform simple hot-swap
      perform_simple_hot_swap(
        table_name,
        sandbox_id,
        module,
        current_version,
        new_beam_data,
        opts
      )
    end
  end

  defp perform_hot_swap_with_dependents(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         opts,
         dependent_modules
       ) do
    Logger.info("Coordinating hot-swap with dependent modules",
      sandbox_id: sandbox_id,
      module: module,
      dependent_modules: dependent_modules
    )

    case perform_simple_hot_swap(
           table_name,
           sandbox_id,
           module,
           current_version,
           new_beam_data,
           opts
         ) do
      {:ok, :hot_swapped} ->
        reload_dependent_modules(
          table_name,
          sandbox_id,
          module,
          current_version,
          opts,
          dependent_modules
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reload_dependent_modules(
         table_name,
         sandbox_id,
         module,
         current_version,
         opts,
         dependent_modules
       ) do
    reload_opts = Keyword.put_new(opts, :force_reload, true)

    case do_cascading_reload(table_name, sandbox_id, dependent_modules, reload_opts) do
      {:ok, :reloaded} ->
        Logger.info("Coordinated hot-swap completed successfully",
          sandbox_id: sandbox_id,
          module: module,
          from_version: current_version.version,
          coordinated_modules: length(dependent_modules)
        )

        {:ok, :hot_swapped}

      {:error, reason} ->
        {:error, {:coordination_failed, reason}}
    end
  end

  defp perform_simple_hot_swap(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         opts
       ) do
    # Find all processes using this module
    processes = find_module_processes(module)

    # Use StatePreservation for advanced state handling
    use_state_preservation = Keyword.get(opts, :use_state_preservation, true)

    if use_state_preservation and processes != [] do
      perform_hot_swap_with_state_preservation(
        table_name,
        sandbox_id,
        module,
        current_version,
        new_beam_data,
        processes,
        opts
      )
    else
      perform_basic_hot_swap(
        table_name,
        sandbox_id,
        module,
        current_version,
        new_beam_data,
        processes,
        opts
      )
    end
  end

  defp perform_hot_swap_with_state_preservation(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         _processes,
         opts
       ) do
    # Capture states using StatePreservation
    preservation_opts = merge_state_preservation_opts(opts)

    case Sandbox.StatePreservation.capture_module_states(module, preservation_opts) do
      {:ok, captured_states} ->
        load_and_restore_with_state_preservation(
          table_name,
          sandbox_id,
          module,
          current_version,
          new_beam_data,
          captured_states,
          preservation_opts
        )

      {:error, reason} ->
        {:error, {:state_capture_failed, reason}}
    end
  rescue
    error ->
      {:error, {:state_preservation_failed, error}}
  end

  defp load_and_restore_with_state_preservation(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         captured_states,
         preservation_opts
       ) do
    # Load new module version
    case :code.load_binary(module, ~c"hot_swap", new_beam_data) do
      {:module, ^module} ->
        register_and_restore_states(
          table_name,
          sandbox_id,
          module,
          current_version,
          new_beam_data,
          captured_states,
          preservation_opts
        )

      {:error, reason} ->
        {:error, {:swap_failed, reason}}
    end
  end

  defp register_and_restore_states(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         captured_states,
         preservation_opts
       ) do
    # Register the new version
    case do_register_module_version(table_name, sandbox_id, module, new_beam_data) do
      {:ok, new_version} ->
        restore_states_after_swap(
          sandbox_id,
          module,
          current_version,
          new_version,
          captured_states,
          preservation_opts
        )

      {:error, reason} ->
        # Rollback module load
        rollback_module_load(module, current_version.beam_data)
        {:error, {:registration_failed, reason}}
    end
  end

  defp restore_states_after_swap(
         sandbox_id,
         module,
         current_version,
         new_version,
         captured_states,
         preservation_opts
       ) do
    # Restore states with StatePreservation
    case Sandbox.StatePreservation.restore_states(
           captured_states,
           current_version.version,
           new_version,
           preservation_opts
         ) do
      {:ok, :restored} ->
        Logger.info("Hot-swapped module with state preservation",
          sandbox_id: sandbox_id,
          module: module,
          from_version: current_version.version,
          to_version: new_version,
          preserved_processes: length(captured_states)
        )

        {:ok, :hot_swapped}

      {:error, reason} ->
        # Rollback on state restoration failure
        rollback_module_load(module, current_version.beam_data)
        {:error, {:state_restoration_failed, reason}}
    end
  end

  defp perform_basic_hot_swap(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         processes,
         opts
       ) do
    # Fallback to basic hot-swap without advanced state preservation
    captured_states = capture_process_states(processes, module)

    # Load new module version
    case :code.load_binary(module, ~c"hot_swap", new_beam_data) do
      {:module, ^module} ->
        register_and_migrate_basic(
          table_name,
          sandbox_id,
          module,
          current_version,
          new_beam_data,
          processes,
          captured_states,
          opts
        )

      {:error, reason} ->
        {:error, {:swap_failed, reason}}
    end
  end

  defp register_and_migrate_basic(
         table_name,
         sandbox_id,
         module,
         current_version,
         new_beam_data,
         processes,
         captured_states,
         opts
       ) do
    # Register the new version
    case do_register_module_version(table_name, sandbox_id, module, new_beam_data) do
      {:ok, new_version} ->
        migrate_states_basic(
          sandbox_id,
          module,
          current_version,
          new_version,
          processes,
          captured_states,
          opts
        )

      {:error, reason} ->
        # Rollback module load
        rollback_module_load(module, current_version.beam_data)
        {:error, {:registration_failed, reason}}
    end
  end

  defp migrate_states_basic(
         sandbox_id,
         module,
         current_version,
         new_version,
         processes,
         captured_states,
         opts
       ) do
    # Get state handler if provided
    state_handler = Keyword.get(opts, :state_handler)

    # Migrate process states
    case migrate_process_states(
           processes,
           captured_states,
           current_version.version,
           new_version,
           state_handler
         ) do
      :ok ->
        Logger.info("Hot-swapped module successfully (basic)",
          sandbox_id: sandbox_id,
          module: module,
          from_version: current_version.version,
          to_version: new_version,
          affected_processes: length(processes)
        )

        {:ok, :hot_swapped}

      {:error, reason} ->
        # Rollback on state migration failure
        rollback_module_load(module, current_version.beam_data)
        {:error, {:state_migration_failed, reason}}
    end
  end

  defp find_dependent_modules(table_name, sandbox_id, target_module) do
    # Find all modules in the sandbox that depend on the target module
    pattern = {{sandbox_id, :"$1"}, :"$2"}

    :ets.match(table_name, pattern)
    |> Enum.filter(fn [module, version_data] ->
      module != target_module and target_module in version_data.dependencies
    end)
    |> Enum.map(fn [module, _version_data] -> module end)
    |> Enum.uniq()
  end

  defp do_rollback_module(table_name, sandbox_id, module, target_version) do
    case find_module_version(table_name, sandbox_id, module, target_version) do
      nil ->
        {:error, :version_not_found}

      {_key, target_module_version} ->
        case :code.load_binary(module, ~c"rollback", target_module_version.beam_data) do
          {:module, ^module} ->
            Logger.info("Rolled back module to version #{target_version}",
              sandbox_id: sandbox_id,
              module: module
            )

            {:ok, :rolled_back}

          {:error, reason} ->
            {:error, {:rollback_failed, reason}}
        end
    end
  end

  defp do_get_module_dependencies(table_name, modules, opts) do
    sandbox_id = Keyword.get(opts, :sandbox_id)

    modules
    |> Enum.reduce(%{}, fn module, acc ->
      dependencies =
        case sandbox_id && get_current_module_version(table_name, sandbox_id, module) do
          {_key, version_data} ->
            version_data.dependencies

          _ ->
            dependencies_from_code(module)
        end

      Map.put(acc, module, dependencies)
    end)
  end

  defp do_calculate_reload_order(table_name, modules, opts) do
    # Get dependency graph
    dependency_graph = do_get_module_dependencies(table_name, modules, opts)

    # Check for circular dependencies first
    case do_detect_circular_dependencies(dependency_graph) do
      {:ok, :no_cycles} ->
        # Perform topological sort
        case topological_sort(dependency_graph, modules) do
          {:ok, sorted_modules} -> {:ok, sorted_modules}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Failed to calculate reload order",
        modules: modules,
        error: inspect(error)
      )

      {:error, {:calculation_failed, error}}
  end

  defp do_cascading_reload(table_name, sandbox_id, modules, opts) do
    # Calculate reload order
    dependency_opts = Keyword.put(opts, :sandbox_id, sandbox_id)

    case do_calculate_reload_order(table_name, modules, dependency_opts) do
      {:ok, ordered_modules} ->
        Logger.info("Starting cascading reload",
          sandbox_id: sandbox_id,
          modules: modules,
          reload_order: ordered_modules
        )

        # Reload modules in dependency order
        result = reload_modules_in_order(table_name, sandbox_id, ordered_modules, opts)

        case result do
          :ok ->
            Logger.info("Cascading reload completed successfully",
              sandbox_id: sandbox_id,
              modules_reloaded: length(ordered_modules)
            )

            {:ok, :reloaded}

          {:error, reason} ->
            Logger.error("Cascading reload failed",
              sandbox_id: sandbox_id,
              reason: reason
            )

            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Cascading reload failed with exception",
        sandbox_id: sandbox_id,
        error: inspect(error)
      )

      {:error, {:cascading_reload_failed, error}}
  end

  defp do_extract_beam_dependencies(beam_data) do
    case :beam_lib.chunks(beam_data, [:imports, :exports, :attributes]) do
      {:ok, {module, chunks}} ->
        imports = extract_imports_from_chunks(chunks)
        exports = extract_exports_from_chunks(chunks)
        attributes = extract_attributes_from_chunks(chunks)

        dependencies = %{
          module: module,
          imports: imports,
          exports: exports,
          attributes: attributes,
          filtered_imports: filter_relevant_imports(imports)
        }

        {:ok, dependencies}

      {:error, :beam_lib, reason} ->
        {:error, {:beam_analysis_failed, reason}}
    end
  rescue
    error ->
      {:error, {:extraction_failed, error}}
  end

  defp do_detect_circular_dependencies(dependency_graph) do
    case find_cycles_in_graph(dependency_graph) do
      [] ->
        {:ok, :no_cycles}

      cycles ->
        Logger.warning("Circular dependencies detected", cycles: cycles)
        {:error, {:circular_dependency, cycles}}
    end
  rescue
    error ->
      {:error, {:cycle_detection_failed, error}}
  end

  defp do_parallel_reload(table_name, sandbox_id, modules, opts) do
    # Get dependency graph
    dependency_opts = Keyword.put(opts, :sandbox_id, sandbox_id)
    dependency_graph = do_get_module_dependencies(table_name, modules, dependency_opts)

    # Group modules by dependency levels
    dependency_levels = calculate_dependency_levels(dependency_graph, modules)

    Logger.info("Starting parallel reload",
      sandbox_id: sandbox_id,
      modules: modules,
      dependency_levels: map_size(dependency_levels)
    )

    # Reload modules level by level, with parallelization within each level
    result = reload_modules_by_levels(table_name, sandbox_id, dependency_levels, opts)

    case result do
      :ok ->
        Logger.info("Parallel reload completed successfully",
          sandbox_id: sandbox_id,
          modules_reloaded: length(modules)
        )

        {:ok, :reloaded}

      {:error, reason} ->
        Logger.error("Parallel reload failed",
          sandbox_id: sandbox_id,
          reason: reason
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Parallel reload failed with exception",
        sandbox_id: sandbox_id,
        error: inspect(error)
      )

      {:error, {:parallel_reload_failed, error}}
  end

  defp do_cleanup_sandbox_modules(table_name, sandbox_id) do
    # Find all modules for this sandbox
    pattern = {{sandbox_id, :"$1"}, :"$2"}
    matches = :ets.match(table_name, pattern)

    # Delete all entries
    Enum.each(matches, fn [module, _] ->
      :ets.delete(table_name, {sandbox_id, module})
    end)

    Logger.debug("Cleaned up modules for sandbox",
      sandbox_id: sandbox_id,
      modules_cleaned: length(matches)
    )

    :ok
  end

  defp do_export_sandbox_modules(table_name, sandbox_id) do
    pattern = {{sandbox_id, :"$1"}, :"$2"}
    matches = :ets.match(table_name, pattern)

    modules_data =
      matches
      |> Enum.reduce(%{}, fn [module, version_data], acc ->
        Map.update(acc, module, [version_data], &[version_data | &1])
      end)
      |> Enum.map(fn {module, versions} ->
        {module, Enum.sort_by(versions, & &1.version, :desc)}
      end)
      |> Map.new()

    {:ok, %{sandbox_id: sandbox_id, modules: modules_data, exported_at: DateTime.utc_now()}}
  end

  # Helper functions

  defp get_current_module_version(table_name, sandbox_id, module) do
    case :ets.lookup(table_name, {sandbox_id, module}) do
      [] ->
        nil

      versions ->
        versions
        |> Enum.max_by(fn {_key, version_data} -> version_data.version end)
    end
  end

  defp find_module_version(table_name, sandbox_id, module, version) do
    :ets.lookup(table_name, {sandbox_id, module})
    |> Enum.find(fn {_key, version_data} -> version_data.version == version end)
  end

  defp cleanup_old_versions(table_name, sandbox_id, module) do
    versions = :ets.lookup(table_name, {sandbox_id, module})

    if length(versions) > @max_versions_per_module do
      versions_to_keep =
        versions
        |> Enum.sort_by(fn {_key, version_data} -> version_data.version end, :desc)
        |> Enum.take(@max_versions_per_module)

      versions_to_delete = versions -- versions_to_keep

      Enum.each(versions_to_delete, fn {key, version_data} ->
        :ets.delete_object(table_name, {key, version_data})
      end)

      Logger.debug("Cleaned up old module versions",
        sandbox_id: sandbox_id,
        module: module,
        deleted_versions: length(versions_to_delete)
      )
    end
  end

  defp calculate_checksum(beam_data) do
    :crypto.hash(:sha256, beam_data)
    |> Base.encode16(case: :lower)
  end

  defp extract_dependencies_from_beam_file(beam_file) do
    case :beam_lib.chunks(beam_file, [:imports]) do
      {:ok, {_module, [{:imports, imports}]}} ->
        imports
        |> Enum.map(fn {module, _func, _arity} -> module end)
        |> Enum.uniq()
        |> Enum.reject(&erlang_stdlib_module?/1)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp dependencies_from_code(module) do
    case :code.which(module) do
      :non_existing ->
        extract_dependencies_from_loaded_module(module)

      :preloaded ->
        extract_dependencies_from_loaded_module(module)

      beam_file when is_list(beam_file) ->
        extract_dependencies_from_beam_file(beam_file)

      _ ->
        extract_dependencies_from_loaded_module(module)
    end
  end

  defp extract_dependencies_from_beam_data(beam_data) do
    case do_extract_beam_dependencies(beam_data) do
      {:ok, %{filtered_imports: imports}} -> imports
      _ -> []
    end
  end

  defp extract_dependencies_from_loaded_module(module) do
    case :code.get_object_code(module) do
      {^module, beam_data, _} -> extract_dependencies_from_beam_data(beam_data)
      _ -> []
    end
  end

  defp erlang_stdlib_module?(module) do
    module_str = to_string(module)

    # Check for Erlang/OTP modules
    String.starts_with?(module_str, ":") or
      module in [
        Enum,
        String,
        Process,
        GenServer,
        Supervisor,
        Agent,
        Task,
        Registry,
        Logger,
        Application,
        Code,
        File,
        Path,
        System,
        IO,
        Kernel
      ]
  end

  defp find_module_processes(module) do
    Process.list()
    |> Enum.filter(fn pid ->
      try do
        case Process.info(pid, :current_function) do
          {:current_function, {^module, _func, _arity}} ->
            true

          _ ->
            # Also check if it's a GenServer/Agent using this module
            case Process.info(pid, :dictionary) do
              {:dictionary, dict} ->
                case Keyword.get(dict, :"$initial_call") do
                  {^module, _func, _arity} -> true
                  _ -> false
                end

              _ ->
                false
            end
        end
      rescue
        _ -> false
      end
    end)
  end

  defp capture_process_states(processes, _module) do
    processes
    |> Enum.reduce(%{}, fn pid, acc ->
      try do
        # Try to get state using sys
        case :sys.get_state(pid, 1000) do
          state when is_map(state) or is_tuple(state) ->
            Map.put(acc, pid, state)

          _ ->
            acc
        end
      rescue
        _ -> acc
      catch
        :exit, _ -> acc
      end
    end)
  end

  defp migrate_process_states(processes, captured_states, old_version, new_version, state_handler) do
    processes
    |> Enum.reduce_while(:ok, fn pid, :ok ->
      case Map.get(captured_states, pid) do
        nil ->
          # No state to migrate
          {:cont, :ok}

        old_state ->
          try do
            new_state =
              if state_handler do
                state_handler.(old_state, old_version, new_version)
              else
                migrate_state(old_state, old_version, new_version)
              end

            # Replace state
            case :sys.replace_state(pid, fn _ -> new_state end) do
              ^new_state -> {:cont, :ok}
              _ -> {:halt, {:error, {:state_replacement_failed, pid}}}
            end
          rescue
            error -> {:halt, {:error, {:state_migration_error, pid, error}}}
          catch
            :exit, reason -> {:halt, {:error, {:process_died, pid, reason}}}
          end
      end
    end)
  end

  defp migrate_state(state, _old_version, _new_version) do
    # Default migration - return state as-is
    # This can be overridden by specific modules or state_handler
    state
  end

  defp rollback_module_load(module, old_beam_data) do
    :code.load_binary(module, ~c"rollback", old_beam_data)
  rescue
    _ -> :ok
  end

  # Advanced dependency analysis helper functions

  defp extract_imports_from_chunks(chunks) do
    case Keyword.get(chunks, :imports) do
      nil ->
        []

      imports ->
        imports
        |> Enum.map(fn {module, _func, _arity} -> module end)
        |> Enum.uniq()
    end
  end

  defp extract_exports_from_chunks(chunks) do
    case Keyword.get(chunks, :exports) do
      nil -> []
      exports -> exports
    end
  end

  defp extract_attributes_from_chunks(chunks) do
    case Keyword.get(chunks, :attributes) do
      nil -> %{}
      attributes -> Map.new(attributes)
    end
  end

  defp filter_relevant_imports(imports) do
    Enum.reject(imports, fn module ->
      erlang_stdlib_module?(module) or elixir_stdlib_module?(module)
    end)
  end

  defp elixir_stdlib_module?(module) do
    module_str = to_string(module)

    # Check for common Elixir stdlib modules
    elixir_modules = [
      "Elixir.Enum",
      "Elixir.Stream",
      "Elixir.String",
      "Elixir.Integer",
      "Elixir.Float",
      "Elixir.Kernel",
      "Elixir.Process",
      "Elixir.GenServer",
      "Elixir.Supervisor",
      "Elixir.Agent",
      "Elixir.Task",
      "Elixir.Registry",
      "Elixir.Logger",
      "Elixir.Application",
      "Elixir.Code",
      "Elixir.File",
      "Elixir.Path",
      "Elixir.System",
      "Elixir.IO"
    ]

    Enum.any?(elixir_modules, &String.starts_with?(module_str, &1))
  end

  defp topological_sort(dependency_graph, modules) do
    # Kahn's algorithm for topological sorting (dependencies before dependents)
    {in_degree, dependents} = build_dependency_indexes(dependency_graph, modules)
    queue = :queue.from_list(Enum.filter(modules, fn m -> Map.get(in_degree, m, 0) == 0 end))

    topological_sort_loop(queue, dependents, in_degree, [])
  rescue
    error -> {:error, {:topological_sort_failed, error}}
  end

  defp topological_sort_loop(queue, dependents, in_degree, result) do
    case :queue.out(queue) do
      {{:value, current}, remaining_queue} ->
        new_result = [current | result]

        # Update in-degrees for dependent modules
        dependencies = Map.get(dependents, current, [])

        {updated_in_degree, updated_queue} =
          update_in_degrees_for_dependents(dependencies, in_degree, remaining_queue)

        topological_sort_loop(updated_queue, dependents, updated_in_degree, new_result)

      {:empty, _} ->
        finalize_topological_sort(result, in_degree)
    end
  end

  defp update_in_degrees_for_dependents(dependencies, in_degree, queue) do
    Enum.reduce(dependencies, {in_degree, queue}, fn dependent, {in_deg_acc, queue_acc} ->
      new_in_degree = Map.update(in_deg_acc, dependent, 0, &(&1 - 1))

      if Map.get(new_in_degree, dependent, 0) == 0 do
        {new_in_degree, :queue.in(dependent, queue_acc)}
      else
        {new_in_degree, queue_acc}
      end
    end)
  end

  defp finalize_topological_sort(result, in_degree) do
    # Check if all modules were processed
    if length(result) == map_size(in_degree) do
      {:ok, Enum.reverse(result)}
    else
      {:error, :circular_dependency_detected}
    end
  end

  defp build_dependency_indexes(dependency_graph, modules) do
    # Initialize all modules with in-degree 0
    initial_degrees = Map.new(modules, &{&1, 0})
    initial_dependents = Map.new(modules, &{&1, []})

    Enum.reduce(dependency_graph, {initial_degrees, initial_dependents}, fn {module, dependencies},
                                                                            {deg_acc, dep_acc} ->
      deps_in_scope = Enum.filter(dependencies, &Map.has_key?(deg_acc, &1))

      updated_degrees = Map.update!(deg_acc, module, &(&1 + length(deps_in_scope)))

      updated_dependents =
        Enum.reduce(deps_in_scope, dep_acc, fn dep, inner_acc ->
          Map.update(inner_acc, dep, [module], &[module | &1])
        end)

      {updated_degrees, updated_dependents}
    end)
  end

  # Using plain maps instead of MapSet to avoid Dialyzer opaque type issues with OTP 28
  @spec find_cycles_in_graph(map()) :: [[atom()]]
  defp find_cycles_in_graph(dependency_graph) do
    visited = %{}
    cycles = []

    Enum.reduce(Map.keys(dependency_graph), {visited, cycles}, fn module, {vis_acc, cycles_acc} ->
      detect_cycle_for_module(module, dependency_graph, vis_acc, cycles_acc)
    end)
    |> elem(1)
  end

  defp detect_cycle_for_module(module, dependency_graph, visited, cycles) do
    if Map.has_key?(visited, module) do
      {visited, cycles}
    else
      case dfs_cycle_detection(module, dependency_graph, visited, %{}, []) do
        {:cycle, cycle_path} -> {Map.put(visited, module, true), [cycle_path | cycles]}
        {:no_cycle, new_visited} -> {new_visited, cycles}
      end
    end
  end

  @spec dfs_cycle_detection(atom(), map(), map(), map(), [atom()]) ::
          {:cycle, [atom()]} | {:no_cycle, map()}
  defp dfs_cycle_detection(module, dependency_graph, visited, rec_stack, path) do
    if Map.has_key?(rec_stack, module) do
      # Found a cycle
      build_cycle_path(module, path)
    else
      traverse_dependencies_for_cycles(module, dependency_graph, visited, rec_stack, path)
    end
  end

  defp build_cycle_path(module, path) do
    cycle_start_index = Enum.find_index(path, &(&1 == module))
    cycle_path = Enum.drop(path, cycle_start_index || 0)
    {:cycle, cycle_path ++ [module]}
  end

  defp traverse_dependencies_for_cycles(module, dependency_graph, visited, rec_stack, path) do
    new_visited = Map.put(visited, module, true)
    new_rec_stack = Map.put(rec_stack, module, true)
    new_path = [module | path]

    dependencies = Map.get(dependency_graph, module, [])

    Enum.reduce_while(dependencies, {:no_cycle, new_visited}, fn dep, {_result, vis_acc} ->
      check_dependency_for_cycle(dep, dependency_graph, vis_acc, new_rec_stack, new_path)
    end)
  end

  defp check_dependency_for_cycle(dep, dependency_graph, visited, rec_stack, path) do
    case dfs_cycle_detection(dep, dependency_graph, visited, rec_stack, path) do
      {:cycle, cycle_path} -> {:halt, {:cycle, cycle_path}}
      {:no_cycle, updated_visited} -> {:cont, {:no_cycle, updated_visited}}
    end
  end

  defp calculate_dependency_levels(dependency_graph, modules) do
    # Calculate the dependency level for each module
    # Level 0: modules with no dependencies
    # Level N: modules that depend only on modules from levels 0 to N-1

    levels = %{}
    remaining_modules = MapSet.new(modules)
    current_level = 0

    calculate_levels_iterative(dependency_graph, remaining_modules, levels, current_level)
  end

  defp calculate_levels_iterative(_dependency_graph, remaining_modules, levels, _current_level)
       when map_size(remaining_modules) == 0 or remaining_modules == %MapSet{} do
    # Check if remaining_modules is empty
    if MapSet.size(remaining_modules) == 0, do: levels, else: levels
  end

  defp calculate_levels_iterative(dependency_graph, remaining_modules, levels, current_level) do
    if MapSet.size(remaining_modules) == 0 do
      levels
    else
      modules_at_level = find_modules_at_level(dependency_graph, remaining_modules, levels)

      process_level_modules(
        dependency_graph,
        remaining_modules,
        levels,
        current_level,
        modules_at_level
      )
    end
  end

  defp find_modules_at_level(dependency_graph, remaining_modules, levels) do
    # Find modules that can be placed at current level
    remaining_modules
    |> Enum.filter(fn module ->
      module_dependencies_satisfied?(dependency_graph, remaining_modules, levels, module)
    end)
  end

  defp module_dependencies_satisfied?(dependency_graph, remaining_modules, levels, module) do
    dependencies = Map.get(dependency_graph, module, [])
    # All dependencies should be in lower levels or not in our module set
    Enum.all?(dependencies, fn dep ->
      not MapSet.member?(remaining_modules, dep) or Map.has_key?(levels, dep)
    end)
  end

  defp process_level_modules(_dependency_graph, remaining_modules, levels, current_level, []) do
    # No progress possible - likely circular dependency
    # Place remaining modules at current level
    place_remaining_at_level(remaining_modules, levels, current_level)
  end

  defp process_level_modules(
         dependency_graph,
         remaining_modules,
         levels,
         current_level,
         modules_at_level
       ) do
    # Add modules to current level
    updated_levels = Map.put(levels, current_level, modules_at_level)

    updated_remaining =
      Enum.reduce(modules_at_level, remaining_modules, &MapSet.delete(&2, &1))

    calculate_levels_iterative(
      dependency_graph,
      updated_remaining,
      updated_levels,
      current_level + 1
    )
  end

  defp place_remaining_at_level(remaining_modules, levels, current_level) do
    remaining_list = MapSet.to_list(remaining_modules)

    Enum.reduce(remaining_list, levels, fn module, acc ->
      Map.update(acc, current_level, [module], &[module | &1])
    end)
  end

  defp reload_modules_in_order(table_name, sandbox_id, ordered_modules, opts) do
    Enum.reduce_while(ordered_modules, :ok, fn module, :ok ->
      case reload_single_module(table_name, sandbox_id, module, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {module, reason}}}
      end
    end)
  end

  defp reload_modules_by_levels(table_name, sandbox_id, dependency_levels, opts) do
    # Sort levels by key (0, 1, 2, ...)
    sorted_levels = Enum.sort_by(dependency_levels, fn {level, _modules} -> level end)

    Enum.reduce_while(sorted_levels, :ok, fn {level, modules}, :ok ->
      Logger.debug("Reloading dependency level #{level}", modules: modules)

      # Reload all modules in this level in parallel
      case reload_modules_parallel(table_name, sandbox_id, modules, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {level, reason}}}
      end
    end)
  end

  defp reload_modules_parallel(table_name, sandbox_id, modules, opts) do
    # Use Task.async_stream for parallel processing
    timeout = Keyword.get(opts, :timeout, 30_000)

    modules
    |> Task.async_stream(
      fn module -> reload_single_module(table_name, sandbox_id, module, opts) end,
      timeout: timeout,
      max_concurrency: System.schedulers_online()
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, :ok -> {:cont, :ok}
      {:ok, {:error, reason}}, :ok -> {:halt, {:error, reason}}
      {:exit, reason}, :ok -> {:halt, {:error, {:task_exit, reason}}}
    end)
  end

  defp reload_single_module(table_name, sandbox_id, module, opts) do
    # Get current module version
    case get_current_module_version(table_name, sandbox_id, module) do
      nil ->
        Logger.debug("Module not found in sandbox, skipping reload",
          sandbox_id: sandbox_id,
          module: module
        )

        :ok

      {_key, current_version} ->
        reload_existing_module(table_name, sandbox_id, module, current_version, opts)
    end
  rescue
    error -> {:error, {:reload_failed, error}}
  end

  defp reload_existing_module(table_name, sandbox_id, module, current_version, opts) do
    force_reload = Keyword.get(opts, :force_reload, false)

    if force_reload do
      force_reload_module(module, current_version)
    else
      hot_swap_reload_module(table_name, sandbox_id, module, current_version, opts)
    end
  end

  defp force_reload_module(module, current_version) do
    case :code.load_binary(module, ~c"reload", current_version.beam_data) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, {:reload_failed, reason}}
    end
  end

  defp hot_swap_reload_module(table_name, sandbox_id, module, current_version, opts) do
    # Perform hot-swap with current BEAM data
    case do_hot_swap_module(
           table_name,
           sandbox_id,
           module,
           current_version.beam_data,
           opts
         ) do
      {:ok, :hot_swapped} -> :ok
      {:ok, :no_change} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_no_circular_dependencies(table_name, sandbox_id, new_module, new_dependencies) do
    # Get all existing modules in the sandbox
    existing_modules = get_sandbox_modules(table_name, sandbox_id)

    # Create a temporary dependency graph including the new module
    temp_graph =
      existing_modules
      |> Enum.reduce(%{}, fn module, acc ->
        case get_current_module_version(table_name, sandbox_id, module) do
          nil -> acc
          {_key, version_data} -> Map.put(acc, module, version_data.dependencies)
        end
      end)
      |> Map.put(new_module, new_dependencies)

    # Check for circular dependencies
    case do_detect_circular_dependencies(temp_graph) do
      {:ok, :no_cycles} -> :ok
      {:error, {:circular_dependency, cycles}} -> {:error, cycles}
    end
  rescue
    error ->
      Logger.warning("Error during circular dependency validation",
        error: inspect(error)
      )

      # Allow registration if validation fails - better to be permissive
      :ok
  end

  defp get_sandbox_modules(table_name, sandbox_id) do
    pattern = {{sandbox_id, :"$1"}, :"$2"}

    :ets.match(table_name, pattern)
    |> Enum.map(fn [module, _version_data] -> module end)
    |> Enum.uniq()
  end

  defp split_server_opts(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_opts = opts |> Keyword.delete(:server) |> Keyword.delete(:table_name)
    {server, call_opts}
  end

  defp resolve_table_name(opts) do
    Keyword.get(opts, :table_name) || Config.table_name(:module_versions, opts)
  end

  defp ensure_table(table_name) do
    case :ets.whereis(table_name) do
      :undefined ->
        try do
          :ets.new(table_name, [:bag, :named_table, :public, read_concurrency: true])
        catch
          :error, :badarg ->
            table_name
        end

      _ ->
        table_name
    end
  end

  defp register_table_name(key, table_name) do
    :persistent_term.put({__MODULE__, key}, table_name)
  end

  defp table_name_for_opts(opts) do
    case Keyword.get(opts, :table_name) do
      nil -> table_name_for_server(Keyword.get(opts, :server, __MODULE__))
      table_name -> table_name
    end
  end

  defp table_name_for_server(server) do
    case :persistent_term.get({__MODULE__, server}, nil) do
      nil -> Config.table_name(:module_versions)
      table_name -> table_name
    end
  end

  defp merge_state_preservation_opts(opts) do
    case Keyword.fetch(opts, :migration_function) do
      {:ok, _} ->
        opts

      :error ->
        case Keyword.fetch(opts, :state_handler) do
          {:ok, handler} -> Keyword.put(opts, :migration_function, handler)
          :error -> opts
        end
    end
  end
end
