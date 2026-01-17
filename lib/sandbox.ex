defmodule Sandbox do
  @moduledoc """
  Sandbox provides isolated OTP application management with hot-reload capabilities.

  This library enables you to create, manage, and hot-reload isolated OTP applications
  (sandboxes) within your Elixir system. Each sandbox runs in complete isolation with
  its own supervision tree, making it perfect for:

  - Learning and experimenting with OTP patterns
  - Building plugin systems
  - Running untrusted code safely
  - Testing supervision strategies
  - Hot-reloading code without affecting the main application

  ## Features

  - **True Isolation**: Each sandbox has its own supervision tree and process hierarchy
  - **Hot Reload**: Update running sandboxes without restarting
  - **Version Management**: Track and rollback module versions
  - **Fault Tolerance**: Sandbox crashes don't affect the host application
  - **Resource Control**: Compile-time limits and process monitoring

  ## Quick Start

  Start the Sandbox system:

      children = [
        Sandbox
      ]
      
      Supervisor.start_link(children, strategy: :one_for_one)

  Create a sandbox:

      {:ok, sandbox} = Sandbox.create_sandbox("my-sandbox", MySupervisor)

  Hot-reload code:

      {:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", new_beam_data)

  Destroy a sandbox:

      :ok = Sandbox.destroy_sandbox("my-sandbox")
  """

  alias Sandbox.Manager
  alias Sandbox.ModuleTransformer
  alias Sandbox.ModuleVersionManager
  alias Sandbox.VirtualCodeTable

  @default_run_timeout 30_000

  @doc """
  Starts the Sandbox system as part of a supervision tree.

  This is typically used when embedding Sandbox in another application.

  ## Examples

      children = [
        Sandbox
      ]
      
      Supervisor.start_link(children, strategy: :one_for_one)
  """
  def child_spec(opts) do
    %{
      id: Sandbox,
      start: {Sandbox.Application, :start, [:normal, opts]},
      type: :supervisor
    }
  end

  # Delegated API functions for convenience

  @doc """
  Creates a new sandbox with the specified ID and configuration.

  ## Arguments

    * `sandbox_id` - Unique identifier for the sandbox
    * `module_or_app` - Either a supervisor module or application name
    * `opts` - Options for sandbox creation

  ## Options

    * `:supervisor_module` - Supervisor module to use (if app name provided)
    * `:sandbox_path` - Path to sandbox code directory
    * `:compile_timeout` - Compilation timeout in milliseconds (default: 30000)
    * `:validate_beams` - Whether to validate BEAM files (default: true)

  ## Examples

      # Using a supervisor module
      {:ok, sandbox} = Sandbox.create_sandbox("test", MyApp.Supervisor)
      
      # Using an application name
      {:ok, sandbox} = Sandbox.create_sandbox("test", :my_app,
        supervisor_module: MyApp.Supervisor,
        sandbox_path: "/path/to/sandbox"
      )
  """
  defdelegate create_sandbox(sandbox_id, module_or_app, opts \\ []),
    to: Sandbox.Manager

  @doc """
  Destroys a sandbox and cleans up all its resources.

  ## Examples

      :ok = Sandbox.destroy_sandbox("my-sandbox")
  """
  defdelegate destroy_sandbox(sandbox_id), to: Sandbox.Manager

  @doc """
  Restarts a sandbox with the same configuration.

  ## Examples

      {:ok, sandbox_info} = Sandbox.restart_sandbox("my-sandbox")
  """
  defdelegate restart_sandbox(sandbox_id), to: Sandbox.Manager

  @doc """
  Hot-reloads a module in a sandbox with new code.

  ## Arguments

    * `sandbox_id` - The sandbox to reload code in
    * `new_beam_data` - The compiled BEAM bytecode
    * `opts` - Options for hot reload

  ## Options

    * `:state_handler` - Function to handle state migration `(old_state, old_version, new_version) -> new_state`

  ## Examples

      # Simple hot reload
      {:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data)
      
      # With custom state migration
      {:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data,
        state_handler: fn old_state, _old_v, _new_v ->
          Map.put(old_state, :upgraded, true)
        end
      )
  """
  defdelegate hot_reload(sandbox_id, new_beam_data, opts \\ []),
    to: Sandbox.Manager,
    as: :hot_reload_sandbox

  @doc """
  Hot-reloads a sandbox using source code.
  """
  def hot_reload_source(sandbox_id, source_code, opts \\ [])

  def hot_reload_source(sandbox_id, source_code, opts) when is_binary(source_code) do
    {server, call_opts} = split_server_opts(opts)

    case Manager.get_hot_reload_context(sandbox_id, server: server) do
      {:ok, context} ->
        do_hot_reload_source(sandbox_id, source_code, context, call_opts)

      {:error, :not_found} ->
        {:error, :sandbox_not_found}

      {:error, reason} ->
        {:error, {:compilation_failed, reason}}
    end
  end

  def hot_reload_source(_sandbox_id, _source_code, _opts) do
    {:error, {:compilation_failed, :invalid_source}}
  end

  @doc """
  Executes a function inside the sandbox execution context with a timeout.
  """
  def run(sandbox_id, fun, opts \\ [])

  def run(sandbox_id, fun, opts) when is_function(fun, 0) do
    {server, run_opts} = split_server_opts(opts)

    case Manager.get_run_context(sandbox_id, server: server) do
      {:ok, context} ->
        run_in_context(sandbox_id, fun, context, run_opts)

      {:error, :not_found} ->
        {:error, :sandbox_not_found}

      {:error, reason} ->
        {:error, {:crashed, reason}}
    end
  end

  def run(_sandbox_id, _fun, _opts) do
    {:error, {:crashed, :invalid_function}}
  end

  @doc """
  Gets information about a specific sandbox.

  ## Examples

      {:ok, info} = Sandbox.get_sandbox_info("my-sandbox")
      info.status #=> :running
  """
  defdelegate get_sandbox_info(sandbox_id), to: Sandbox.Manager

  @doc """
  Lists all active sandboxes.

  ## Examples

      sandboxes = Sandbox.list_sandboxes()
      Enum.map(sandboxes, & &1.id)
  """
  defdelegate list_sandboxes(), to: Sandbox.Manager

  @doc """
  Gets the main process PID for a sandbox.

  ## Examples

      {:ok, pid} = Sandbox.get_sandbox_pid("my-sandbox")
  """
  defdelegate get_sandbox_pid(sandbox_id), to: Sandbox.Manager

  @doc """
  Returns aggregated resource usage for a sandbox.
  """
  defdelegate resource_usage(sandbox_id, opts \\ []), to: Sandbox.Manager

  # Module version management

  @doc """
  Gets the current version of a module in a sandbox.

  ## Examples

      {:ok, 3} = Sandbox.get_module_version("my-sandbox", MyModule)
  """
  defdelegate get_module_version(sandbox_id, module),
    to: Sandbox.ModuleVersionManager,
    as: :get_current_version

  @doc """
  Lists all versions of a module in a sandbox.

  ## Examples

      versions = Sandbox.list_module_versions("my-sandbox", MyModule)
      Enum.map(versions, & &1.version) #=> [3, 2, 1]
  """
  defdelegate list_module_versions(sandbox_id, module),
    to: Sandbox.ModuleVersionManager

  @doc """
  Rolls back a module to a previous version.

  ## Examples

      {:ok, :rolled_back} = Sandbox.rollback_module("my-sandbox", MyModule, 2)
  """
  defdelegate rollback_module(sandbox_id, module, target_version),
    to: Sandbox.ModuleVersionManager

  @doc """
  Gets the version history for a module.

  ## Examples

      history = Sandbox.get_version_history("my-sandbox", MyModule)
      history.current_version #=> 3
      history.total_versions #=> 3
  """
  defdelegate get_version_history(sandbox_id, module),
    to: Sandbox.ModuleVersionManager

  # Compilation utilities

  @doc """
  Compiles a sandbox directory in isolation.

  ## Examples

      {:ok, compile_info} = Sandbox.compile_sandbox("/path/to/sandbox")
      compile_info.beam_files #=> ["path/to/module1.beam", ...]
  """
  defdelegate compile_sandbox(sandbox_path, opts \\ []),
    to: Sandbox.IsolatedCompiler

  @doc """
  Compiles a single Elixir file in isolation.

  ## Examples

      {:ok, compile_info} = Sandbox.compile_file("/path/to/file.ex")
  """
  defdelegate compile_file(file_path, opts \\ []),
    to: Sandbox.IsolatedCompiler

  @doc """
  Creates multiple sandboxes with bounded concurrency.
  """
  def batch_create(configs, opts \\ []) when is_list(configs) do
    {stream_opts, call_opts} = split_batch_opts(opts)

    configs
    |> Task.async_stream(
      fn {sandbox_id, module_or_app, create_opts} ->
        merged_opts = Keyword.merge(create_opts, call_opts)
        result = safe_batch_call(fn -> create_sandbox(sandbox_id, module_or_app, merged_opts) end)
        {sandbox_id, result}
      end,
      max_concurrency: Keyword.get(stream_opts, :max_concurrency, System.schedulers_online()),
      timeout: Keyword.get(stream_opts, :batch_timeout, :infinity)
    )
    |> Enum.map(&normalize_batch_result/1)
  end

  @doc """
  Destroys multiple sandboxes with bounded concurrency.
  """
  def batch_destroy(sandbox_ids, opts \\ []) when is_list(sandbox_ids) do
    {stream_opts, call_opts} = split_batch_opts(opts)

    sandbox_ids
    |> Task.async_stream(
      fn sandbox_id ->
        result = safe_batch_call(fn -> Manager.destroy_sandbox(sandbox_id, call_opts) end)
        {sandbox_id, result}
      end,
      max_concurrency: Keyword.get(stream_opts, :max_concurrency, System.schedulers_online()),
      timeout: Keyword.get(stream_opts, :batch_timeout, :infinity)
    )
    |> Enum.map(&normalize_batch_result/1)
  end

  @doc """
  Runs a function across multiple sandboxes with bounded concurrency.
  """
  def batch_run(sandbox_ids, fun, opts \\ []) when is_list(sandbox_ids) do
    {stream_opts, call_opts} = split_batch_opts(opts)

    sandbox_ids
    |> Task.async_stream(
      fn sandbox_id ->
        result = safe_batch_call(fn -> run(sandbox_id, fun, call_opts) end)
        {sandbox_id, result}
      end,
      max_concurrency: Keyword.get(stream_opts, :max_concurrency, System.schedulers_online()),
      timeout: Keyword.get(stream_opts, :batch_timeout, :infinity)
    )
    |> Enum.map(&normalize_batch_result/1)
  end

  @doc """
  Hot-reloads multiple sandboxes with bounded concurrency.
  """
  def batch_hot_reload(sandbox_ids, beam_or_source, opts \\ []) when is_list(sandbox_ids) do
    {stream_opts, call_opts} = split_batch_opts(opts)
    {mode, payload} = normalize_hot_reload_payload(beam_or_source)
    runner = hot_reload_runner(mode, payload, call_opts)

    sandbox_ids
    |> Task.async_stream(
      fn sandbox_id ->
        result = safe_batch_call(fn -> runner.(sandbox_id) end)
        {sandbox_id, result}
      end,
      max_concurrency: Keyword.get(stream_opts, :max_concurrency, System.schedulers_online()),
      timeout: Keyword.get(stream_opts, :batch_timeout, :infinity)
    )
    |> Enum.map(&normalize_batch_result/1)
  end

  defp run_in_context(sandbox_id, fun, context, run_opts) do
    run_supervisor_pid = Map.get(context, :run_supervisor_pid)
    resource_limits = Map.get(context, :resource_limits, %{})
    timeout = effective_timeout(run_opts, resource_limits)

    if is_pid(run_supervisor_pid) and Process.alive?(run_supervisor_pid) do
      start_and_await_run(run_supervisor_pid, sandbox_id, fun, timeout)
    else
      {:error, {:crashed, :run_supervisor_unavailable}}
    end
  rescue
    error ->
      {:error, {:crashed, error}}
  catch
    :exit, reason ->
      {:error, {:crashed, reason}}
  end

  defp effective_timeout(opts, resource_limits) do
    user_timeout = Keyword.get(opts, :timeout, @default_run_timeout)
    limit_timeout = Map.get(resource_limits, :max_execution_time)

    cond do
      is_integer(user_timeout) and is_integer(limit_timeout) ->
        min(user_timeout, limit_timeout)

      is_integer(user_timeout) ->
        user_timeout

      is_integer(limit_timeout) ->
        limit_timeout

      true ->
        @default_run_timeout
    end
  end

  defp do_hot_reload_source(sandbox_id, source_code, context, opts) do
    namespace_prefix =
      context.module_namespace_prefix ||
        ModuleTransformer.create_unique_namespace(
          ModuleTransformer.sanitize_sandbox_id(sandbox_id)
        )

    with {:ok, transformed_code, module_mappings} <-
           ModuleTransformer.transform_source(source_code, sandbox_id,
             namespace_prefix: namespace_prefix
           ),
         {:ok, modules} <- compile_transformed_source(transformed_code),
         {:ok, :hot_reloaded} <- load_hot_reload_modules(sandbox_id, modules, context, opts) do
      register_module_mappings(
        sandbox_id,
        module_mappings,
        context.table_prefixes.module_registry
      )

      {:ok, :hot_reloaded}
    else
      {:error, {:parse_error, _line, _error, _token} = reason} ->
        {:error, {:parse_failed, reason}}

      {:error, reason} ->
        {:error, {:compilation_failed, reason}}
    end
  end

  defp register_module_mappings(sandbox_id, module_mappings, table_prefix) do
    Enum.each(module_mappings, fn {original, transformed} ->
      ModuleTransformer.register_module_mapping(sandbox_id, original, transformed,
        table_prefix: table_prefix
      )
    end)
  end

  defp compile_transformed_source(transformed_code) do
    {:ok, Code.compile_string(transformed_code)}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp load_hot_reload_modules(sandbox_id, modules, context, _opts) do
    modules
    |> Enum.reduce_while(:ok, fn {module, beam_data}, :ok ->
      with :ok <- load_module_binary(module, beam_data),
           :ok <-
             VirtualCodeTable.load_module(sandbox_id, module, beam_data,
               force_reload: true,
               table_prefix: context.table_prefixes.virtual_code
             ),
           {:ok, _version} <-
             ModuleVersionManager.register_module_version(
               sandbox_id,
               module,
               beam_data,
               server: context.services.module_version_manager
             ) do
        {:cont, :ok}
      else
        {:error, {:module_already_loaded, ^module}} ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> {:ok, :hot_reloaded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_module_binary(module, beam_data) do
    case :code.load_binary(module, ~c"hot_reload_source", beam_data) do
      {:module, ^module} -> :ok
      {:error, reason} -> {:error, {:load_failed, module, reason}}
    end
  rescue
    error ->
      {:error, {:load_failed, module, error}}
  end

  defp split_server_opts(opts) do
    {Keyword.get(opts, :server, Manager), Keyword.delete(opts, :server)}
  end

  defp split_batch_opts(opts) do
    stream_opts = Keyword.take(opts, [:max_concurrency, :batch_timeout])
    call_opts = Keyword.drop(opts, [:max_concurrency, :batch_timeout])
    {stream_opts, call_opts}
  end

  defp normalize_batch_result({:ok, result}), do: result
  defp normalize_batch_result({:exit, reason}), do: {:error, {:crashed, reason}}

  defp safe_batch_call(fun) do
    fun.()
  rescue
    error -> {:error, {:crashed, error}}
  catch
    :exit, reason -> {:error, {:crashed, reason}}
    :throw, reason -> {:error, {:crashed, reason}}
  end

  defp normalize_hot_reload_payload({:beam, beam}) when is_binary(beam), do: {:beam, beam}

  defp normalize_hot_reload_payload({:source, source}) when is_binary(source),
    do: {:source, source}

  defp normalize_hot_reload_payload(payload) when is_binary(payload) do
    if beam_binary?(payload) do
      {:beam, payload}
    else
      {:source, payload}
    end
  end

  defp normalize_hot_reload_payload(_payload), do: {:source, ""}

  defp hot_reload_runner(:beam, payload, opts) do
    fn sandbox_id -> hot_reload(sandbox_id, payload, opts) end
  end

  defp hot_reload_runner(:source, payload, opts) do
    fn sandbox_id -> hot_reload_source(sandbox_id, payload, opts) end
  end

  defp beam_binary?(binary) when is_binary(binary) do
    case :beam_lib.info(binary) do
      info when is_list(info) -> true
      {:error, :beam_lib, _} -> false
    end
  rescue
    _ -> false
  end

  defp start_and_await_run(run_supervisor_pid, sandbox_id, fun, timeout) do
    parent = self()

    case Task.Supervisor.start_child(run_supervisor_pid, fn ->
           Process.put(:sandbox_id, sandbox_id)
           send(parent, {:sandbox_run_result, self(), run_fun_safely(fun)})
         end) do
      {:ok, pid} ->
        await_run_result(pid, timeout)

      {:error, reason} ->
        {:error, {:crashed, reason}}

      :ignore ->
        {:error, {:crashed, :ignored}}
    end
  end

  defp run_fun_safely(fun) do
    {:ok, fun.()}
  rescue
    error ->
      {:error, {:crashed, error}}
  catch
    :exit, reason ->
      {:error, {:crashed, reason}}

    :throw, reason ->
      {:error, {:crashed, reason}}
  end

  defp await_run_result(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:sandbox_run_result, ^pid, result} ->
        Process.demonitor(ref, [:flush])
        result

      {:DOWN, ^ref, :process, ^pid, reason} ->
        fetch_result_or_crash(pid, reason)
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        {:error, :timeout}
    end
  end

  defp fetch_result_or_crash(pid, reason) do
    receive do
      {:sandbox_run_result, ^pid, result} -> result
    after
      0 -> {:error, {:crashed, reason}}
    end
  end
end
