defmodule Sandbox.StatePreservation do
  @moduledoc """
  Handles GenServer state preservation during hot-reloads.

  This module provides comprehensive state preservation capabilities including:
  - GenServer state capture and restoration
  - Custom migration function support with error handling and rollback
  - Supervisor child spec migration with minimal process disruption
  - State compatibility validation with schema change detection
  - Advanced state schema validation and migration
  - Comprehensive error handling and recovery mechanisms
  """

  use GenServer
  require Logger

  @type state_capture :: %{
          pid: pid(),
          module: atom(),
          state: any(),
          captured_at: DateTime.t(),
          process_info: map(),
          supervisor_info: map() | nil
        }

  @type migration_function :: (old_state :: any(),
                               old_version :: non_neg_integer(),
                               new_version :: non_neg_integer() ->
                                 any())

  @type migration_result ::
          {:ok, any()}
          | {:error, :migration_failed | :incompatible_state | :process_died | any()}

  @type preservation_options :: [
          timeout: non_neg_integer(),
          validate_compatibility: boolean(),
          migration_function: migration_function() | nil,
          preserve_supervisor_specs: boolean(),
          rollback_on_failure: boolean()
        ]

  # Client API

  @doc """
  Starts the StatePreservation GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Captures the state of all processes using a specific module.
  """
  @spec capture_module_states(atom(), preservation_options()) ::
          {:ok, [state_capture()]} | {:error, any()}
  def capture_module_states(module, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:capture_module_states, module, call_opts}, 30_000)
  end

  @doc """
  Captures the state of a specific process.
  """
  @spec capture_process_state(pid(), preservation_options()) ::
          {:ok, state_capture()} | {:error, any()}
  def capture_process_state(pid, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:capture_process_state, pid, call_opts})
  end

  @doc """
  Restores state to processes after hot-reload.
  """
  @spec restore_states(
          [state_capture()],
          non_neg_integer(),
          non_neg_integer(),
          preservation_options()
        ) ::
          {:ok, :restored} | {:error, any()}
  def restore_states(captured_states, old_version, new_version, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)

    GenServer.call(
      server,
      {:restore_states, captured_states, old_version, new_version, call_opts},
      30_000
    )
  end

  @doc """
  Validates state compatibility between versions.
  """
  @spec validate_state_compatibility(any(), any()) ::
          {:ok, :compatible} | {:error, :incompatible | any()}
  def validate_state_compatibility(old_state, new_state) do
    GenServer.call(__MODULE__, {:validate_state_compatibility, old_state, new_state})
  end

  @doc """
  Migrates supervisor child specifications during hot-reload.
  """
  @spec migrate_supervisor_specs(pid(), atom(), preservation_options()) ::
          {:ok, :migrated} | {:error, any()}
  def migrate_supervisor_specs(supervisor_pid, new_module, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)
    GenServer.call(server, {:migrate_supervisor_specs, supervisor_pid, new_module, call_opts})
  end

  @doc """
  Performs a complete state preservation cycle for a module hot-reload.
  """
  @spec preserve_and_restore(atom(), non_neg_integer(), non_neg_integer(), preservation_options()) ::
          {:ok, :completed} | {:error, any()}
  def preserve_and_restore(module, old_version, new_version, opts \\ []) do
    {server, call_opts} = split_server_opts(opts)

    GenServer.call(
      server,
      {:preserve_and_restore, module, old_version, new_version, call_opts},
      60_000
    )
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    Logger.info("StatePreservation started", opts: opts)

    state = %{
      captured_states: %{},
      migration_history: [],
      active_migrations: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:capture_module_states, module, opts}, _from, state) do
    result = do_capture_module_states(module, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:capture_process_state, pid, opts}, _from, state) do
    result = do_capture_process_state(pid, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call(
        {:restore_states, captured_states, old_version, new_version, opts},
        _from,
        state
      ) do
    result = do_restore_states(captured_states, old_version, new_version, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:validate_state_compatibility, old_state, new_state}, _from, state) do
    result = do_validate_state_compatibility(old_state, new_state)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:migrate_supervisor_specs, supervisor_pid, new_module, opts}, _from, state) do
    result = do_migrate_supervisor_specs(supervisor_pid, new_module, opts)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:preserve_and_restore, module, old_version, new_version, opts}, _from, state) do
    result = do_preserve_and_restore(module, old_version, new_version, opts)
    {:reply, result, state}
  end

  # Private implementation functions

  defp do_capture_module_states(module, opts) do
    _timeout = Keyword.get(opts, :timeout, 5000)

    try do
      processes = find_module_processes(module)

      captured_states =
        processes
        |> Enum.map(fn pid ->
          case do_capture_process_state(pid, opts) do
            {:ok, capture} -> capture
            {:error, _reason} -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      Logger.debug("Captured states for module #{module}",
        processes_found: length(processes),
        states_captured: length(captured_states)
      )

      {:ok, captured_states}
    rescue
      error ->
        Logger.error("Failed to capture module states",
          module: module,
          error: inspect(error)
        )

        {:error, {:capture_failed, error}}
    end
  end

  defp do_capture_process_state(pid, opts) do
    timeout = Keyword.get(opts, :timeout, 5000)
    preserve_supervisor_specs = Keyword.get(opts, :preserve_supervisor_specs, true)

    try do
      # Check if process is alive
      unless Process.alive?(pid) do
        throw({:error, :process_dead})
      end

      # Get basic process info
      process_info = get_process_info(pid)

      # Determine module
      module = determine_process_module(pid, process_info)

      # Capture state using sys module
      state = capture_sys_state(pid, timeout)

      # Get supervisor info if needed
      supervisor_info =
        if preserve_supervisor_specs do
          get_supervisor_info(pid)
        else
          nil
        end

      capture = %{
        pid: pid,
        module: module,
        state: state,
        captured_at: DateTime.utc_now(),
        process_info: process_info,
        supervisor_info: supervisor_info
      }

      Logger.debug("Captured process state",
        pid: inspect(pid),
        module: module,
        state_size: byte_size(:erlang.term_to_binary(state))
      )

      {:ok, capture}
    rescue
      error ->
        Logger.warning("Failed to capture process state",
          pid: inspect(pid),
          error: inspect(error)
        )

        {:error, {:capture_failed, error}}
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_restore_states(captured_states, old_version, new_version, opts) do
    _migration_function = Keyword.get(opts, :migration_function)
    _validate_compatibility = Keyword.get(opts, :validate_compatibility, true)
    rollback_on_failure = Keyword.get(opts, :rollback_on_failure, true)

    try do
      # Group by module for batch processing
      states_by_module = Enum.group_by(captured_states, & &1.module)

      results =
        Enum.map(states_by_module, fn {module, states} ->
          restore_module_states(module, states, old_version, new_version, opts)
        end)

      # Check if all restorations succeeded
      case Enum.find(results, fn result -> match?({:error, _}, result) end) do
        nil ->
          Logger.info("Successfully restored all states",
            modules: Map.keys(states_by_module),
            total_processes: length(captured_states)
          )

          {:ok, :restored}

        {:error, reason} ->
          if rollback_on_failure do
            Logger.warning("State restoration failed, attempting rollback", reason: reason)
            # Attempt to rollback successful restorations
            rollback_restorations(captured_states)
          end

          {:error, reason}
      end
    rescue
      error ->
        Logger.error("State restoration failed", error: inspect(error))
        {:error, {:restoration_failed, error}}
    end
  end

  defp restore_module_states(_module, states, old_version, new_version, opts) do
    migration_function = Keyword.get(opts, :migration_function)
    validate_compatibility = Keyword.get(opts, :validate_compatibility, true)

    Enum.reduce_while(states, :ok, fn capture, :ok ->
      case restore_single_state(
             capture,
             old_version,
             new_version,
             migration_function,
             validate_compatibility
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {capture.pid, reason}}}
      end
    end)
  end

  defp restore_single_state(
         capture,
         old_version,
         new_version,
         migration_function,
         validate_compatibility
       ) do
    %{pid: pid, state: old_state, module: module} = capture

    try do
      # Check if process is still alive
      if Process.alive?(pid) do
        # Apply migration function if provided
        new_state =
          if migration_function do
            migration_function.(old_state, old_version, new_version)
          else
            apply_default_migration(old_state, old_version, new_version)
          end

        # Validate compatibility if requested
        if validate_compatibility do
          case do_validate_state_compatibility(old_state, new_state) do
            {:ok, :compatible} -> :ok
            {:error, reason} -> throw({:error, {:incompatible_state, reason}})
          end
        end

        # Replace the state
        case replace_process_state(pid, new_state) do
          :ok ->
            Logger.debug("Successfully restored state",
              pid: inspect(pid),
              module: module
            )

            :ok

          {:error, reason} ->
            {:error, {:state_replacement_failed, reason}}
        end
      else
        Logger.debug("Process died during hot-reload, skipping state restoration",
          pid: inspect(pid),
          module: module
        )

        :ok
      end
    rescue
      error ->
        Logger.error("Failed to restore single state",
          pid: inspect(pid),
          module: capture.module,
          error: inspect(error)
        )

        {:error, {:restoration_error, error}}
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_validate_state_compatibility(old_state, new_state) do
    # Basic type compatibility check
    if compatible_types?(old_state, new_state) do
      # Structural compatibility check for maps and tuples
      case {old_state, new_state} do
        {old_map, new_map} when is_map(old_map) and is_map(new_map) ->
          validate_map_compatibility(old_map, new_map)

        {old_tuple, new_tuple} when is_tuple(old_tuple) and is_tuple(new_tuple) ->
          validate_tuple_compatibility(old_tuple, new_tuple)

        _ ->
          {:ok, :compatible}
      end
    else
      {:error, :type_mismatch}
    end
  rescue
    error ->
      {:error, {:validation_error, error}}
  end

  defp do_migrate_supervisor_specs(supervisor_pid, new_module, opts) do
    _timeout = Keyword.get(opts, :timeout, 5000)

    try do
      unless Process.alive?(supervisor_pid) do
        throw({:error, :supervisor_dead})
      end

      # Get current child specs
      current_specs = Supervisor.which_children(supervisor_pid)

      # Find specs that need updating
      specs_to_update =
        Enum.filter(current_specs, fn {_id, _pid, _type, modules} ->
          case modules do
            [module] when module == new_module -> true
            modules when is_list(modules) -> new_module in modules
            _ -> false
          end
        end)

      # Update each spec
      results =
        Enum.map(specs_to_update, fn {child_id, child_pid, type, _modules} ->
          update_child_spec(supervisor_pid, child_id, child_pid, new_module, type)
        end)

      case Enum.find(results, fn result -> match?({:error, _}, result) end) do
        nil ->
          Logger.info("Successfully migrated supervisor specs",
            supervisor: inspect(supervisor_pid),
            updated_specs: length(specs_to_update)
          )

          {:ok, :migrated}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error ->
        Logger.error("Failed to migrate supervisor specs",
          supervisor: inspect(supervisor_pid),
          error: inspect(error)
        )

        {:error, {:migration_failed, error}}
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_preserve_and_restore(module, old_version, new_version, opts) do
    # Step 1: Capture states
    case do_capture_module_states(module, opts) do
      {:ok, captured_states} ->
        Logger.debug("Captured #{length(captured_states)} states for module #{module}")

        # Step 2: Restore states after hot-reload
        case do_restore_states(captured_states, old_version, new_version, opts) do
          {:ok, :restored} ->
            Logger.info("Completed state preservation cycle",
              module: module,
              processes: length(captured_states)
            )

            {:ok, :completed}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      Logger.error("State preservation cycle failed",
        module: module,
        error: inspect(error)
      )

      {:error, {:preservation_cycle_failed, error}}
  end

  # Helper functions

  defp find_module_processes(module) do
    Process.list()
    |> Enum.filter(fn pid ->
      try do
        process_module = determine_process_module(pid, get_process_info(pid))
        process_module == module
      rescue
        _ -> false
      end
    end)
  end

  defp get_process_info(pid) do
    info_keys = [
      :current_function,
      :initial_call,
      :dictionary,
      :registered_name,
      :links,
      :monitors
    ]

    info_keys
    |> Enum.map(fn key -> {key, Process.info(pid, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  rescue
    _ -> %{}
  end

  defp determine_process_module(_pid, process_info) do
    # Try multiple methods to determine the module, prioritizing GenServer callback modules
    # Check process dictionary for GenServer callback module (most reliable for GenServers)
    case Map.get(process_info, :dictionary) do
      {:dictionary, dict} ->
        case Keyword.get(dict, :"$initial_call") do
          # GenServer callback module
          {module, :init, 1} ->
            module

          {module, _func, _arity} ->
            module

          _ ->
            # Fallback to other methods
            determine_module_fallback(process_info)
        end

      _ ->
        determine_module_fallback(process_info)
    end
  end

  defp determine_module_fallback(process_info) do
    cond do
      # Check current function
      match?(
        {:current_function, {_module, _func, _arity}},
        Map.get(process_info, :current_function)
      ) ->
        {module, _func, _arity} = elem(Map.get(process_info, :current_function), 1)
        if module == :gen_server, do: :unknown, else: module

      # Check initial call
      match?({:initial_call, {_module, _func, _arity}}, Map.get(process_info, :initial_call)) ->
        {module, _func, _arity} = elem(Map.get(process_info, :initial_call), 1)
        if module in [:proc_lib, :gen_server], do: :unknown, else: module

      true ->
        :unknown
    end
  end

  defp capture_sys_state(pid, timeout) do
    :sys.get_state(pid, timeout)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp get_supervisor_info(pid) do
    # Check if this process is supervised
    case Process.info(pid, :links) do
      {:links, links} ->
        supervisor_pids = Enum.filter(links, &supervisor_process?/1)
        build_supervisor_info(supervisor_pids, pid)

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp supervisor_process?(linked_pid) do
    case Process.info(linked_pid, :dictionary) do
      {:dictionary, dict} ->
        supervisor_initial_call?(Keyword.get(dict, :"$initial_call"))

      _ ->
        false
    end
  rescue
    _ -> false
  end

  defp supervisor_initial_call?({Supervisor, _, _}), do: true
  defp supervisor_initial_call?({:supervisor, _, _}), do: true
  defp supervisor_initial_call?(_), do: false

  defp build_supervisor_info([supervisor_pid | _], pid) do
    %{
      supervisor_pid: supervisor_pid,
      child_spec: get_child_spec(supervisor_pid, pid)
    }
  end

  defp build_supervisor_info([], _pid), do: nil

  defp get_child_spec(supervisor_pid, child_pid) do
    Supervisor.which_children(supervisor_pid)
    |> Enum.find(fn {_id, pid, _type, _modules} -> pid == child_pid end)
  rescue
    _ -> nil
  end

  defp apply_default_migration(state, _old_version, _new_version) do
    # Default migration strategy - return state as-is
    # This can be overridden by providing a custom migration function
    state
  end

  defp compatible_types?(old_state, new_state) do
    # Check if the basic types are compatible
    type_tag(old_state) == type_tag(new_state)
  end

  defp type_tag(nil), do: :nil_type
  defp type_tag(x) when is_atom(x), do: :atom
  defp type_tag(x) when is_number(x), do: :number
  defp type_tag(x) when is_binary(x), do: :binary
  defp type_tag(x) when is_list(x), do: :list
  defp type_tag(x) when is_map(x), do: :map
  defp type_tag(x) when is_tuple(x), do: :tuple
  defp type_tag(x) when is_pid(x), do: :pid
  defp type_tag(x) when is_reference(x), do: :reference
  defp type_tag(_), do: :other

  defp validate_map_compatibility(old_map, new_map) do
    # Check if all required keys from old map exist in new map
    old_keys = Map.keys(old_map)
    new_keys = Map.keys(new_map)

    missing_keys = old_keys -- new_keys

    if missing_keys == [] do
      {:ok, :compatible}
    else
      {:error, {:missing_keys, missing_keys}}
    end
  end

  defp validate_tuple_compatibility(old_tuple, new_tuple) do
    old_size = tuple_size(old_tuple)
    new_size = tuple_size(new_tuple)

    if old_size == new_size do
      {:ok, :compatible}
    else
      {:error, {:size_mismatch, old_size, new_size}}
    end
  end

  defp replace_process_state(pid, new_state) do
    case :sys.replace_state(pid, fn _old_state -> new_state end) do
      ^new_state -> :ok
      _ -> {:error, :replacement_failed}
    end
  rescue
    error -> {:error, {:sys_error, error}}
  catch
    :exit, reason -> {:error, {:process_exit, reason}}
  end

  defp update_child_spec(supervisor_pid, child_id, child_pid, _new_module, _type) do
    # This is a simplified approach - in practice, you might need more sophisticated
    # child spec updating depending on your supervisor setup

    # First, terminate the child if it's running
    if Process.alive?(child_pid) do
      terminate_and_restart_child(supervisor_pid, child_id)
    else
      # Child is not running, just restart it
      restart_child(supervisor_pid, child_id)
    end
  rescue
    error -> {:error, {:update_failed, error}}
  end

  defp terminate_and_restart_child(supervisor_pid, child_id) do
    case Supervisor.terminate_child(supervisor_pid, child_id) do
      :ok -> restart_child(supervisor_pid, child_id)
      {:error, reason} -> {:error, {:terminate_failed, reason}}
    end
  end

  defp restart_child(supervisor_pid, child_id) do
    case Supervisor.restart_child(supervisor_pid, child_id) do
      {:ok, _new_pid} -> :ok
      {:ok, _new_pid, _info} -> :ok
      # Child was already removed
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, {:restart_failed, reason}}
    end
  end

  defp rollback_restorations(captured_states) do
    # Attempt to restore original states
    Enum.each(captured_states, fn capture ->
      try do
        if Process.alive?(capture.pid) do
          replace_process_state(capture.pid, capture.state)
        end
      rescue
        _ -> :ok
      end
    end)
  end

  defp split_server_opts(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    call_opts = Keyword.delete(opts, :server)
    {server, call_opts}
  end
end
