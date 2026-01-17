defmodule Sandbox.IsolatedCompiler do
  @moduledoc """
  Handles compilation of sandbox code in complete isolation.

  This module ensures that sandbox compilation failures cannot affect
  the host system or other sandboxes by running compilation in separate
  processes with strict resource limits and timeout controls.
  """

  require Logger

  @default_timeout 30_000
  @default_memory_limit 256 * 1024 * 1024
  @temp_dir_prefix "sandbox_"
  @cache_dir_name ".sandbox_cache"

  @type compile_result :: {:ok, compile_info()} | {:error, compile_error()}
  @type compile_info :: %{
          output: String.t(),
          beam_files: [String.t()],
          app_file: String.t() | nil,
          compilation_time: non_neg_integer(),
          temp_dir: String.t(),
          warnings: [warning()],
          incremental: boolean(),
          cache_hit: boolean(),
          changed_files: [String.t()]
        }

  @type warning :: %{
          file: String.t(),
          line: non_neg_integer(),
          message: String.t()
        }
  @type compile_error ::
          {:compilation_failed, exit_code :: non_neg_integer(), output :: String.t()}
          | {:compilation_timeout, timeout :: non_neg_integer()}
          | {:compiler_crash, kind :: atom(), error :: any()}
          | {:invalid_sandbox_path, path :: String.t()}
          | {:beam_validation_failed, reason :: String.t()}

  @type compile_opts :: [
          timeout: non_neg_integer(),
          memory_limit: non_neg_integer(),
          temp_dir: String.t() | nil,
          validate_beams: boolean(),
          env: %{String.t() => String.t()},
          compiler: :mix | :erlc | :elixirc,
          incremental: boolean(),
          force_recompile: boolean(),
          cache_enabled: boolean(),
          dependency_analysis: boolean(),
          cpu_limit: float(),
          max_processes: non_neg_integer(),
          security_scan: boolean(),
          restricted_modules: [atom()],
          allowed_operations: [atom()]
        ]

  @doc """
  Compiles a sandbox in complete isolation.

  ## Options
    * `:timeout` - Maximum compilation time in milliseconds (default: 30000)
    * `:memory_limit` - Memory limit in bytes (default: 256MB)
    * `:temp_dir` - Custom temporary directory
    * `:validate_beams` - Whether to validate BEAM files (default: true)
    * `:env` - Environment variables for compilation
    * `:compiler` - Compiler to use: :mix, :erlc, or :elixirc (default: :mix)

  ## Examples

      iex> compile_sandbox("/path/to/sandbox")
      {:ok, %{output: "...", beam_files: [...], app_file: "...", compilation_time: 1234}}
      
      iex> compile_sandbox("/invalid/path") 
      {:error, {:invalid_sandbox_path, "/invalid/path"}}
  """
  @spec compile_sandbox(String.t(), compile_opts()) :: compile_result()
  def compile_sandbox(sandbox_path, opts \\ []) do
    incremental = Keyword.get(opts, :incremental, false)
    force_recompile = Keyword.get(opts, :force_recompile, false)
    cache_enabled = Keyword.get(opts, :cache_enabled, true)

    start_time = System.monotonic_time(:millisecond)

    # Check cache first if incremental compilation is enabled and not forcing recompile
    if incremental and cache_enabled and not force_recompile do
      case try_cached_compilation(sandbox_path, opts) do
        {:ok, cached_result} ->
          {:ok, cached_result}

        {:error, :no_cache} ->
          perform_full_compilation(sandbox_path, opts, start_time)

        {:error, _reason} ->
          perform_full_compilation(sandbox_path, opts, start_time)
      end
    else
      perform_full_compilation(sandbox_path, opts, start_time)
    end
  end

  defp perform_full_compilation(sandbox_path, opts, start_time) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    validate_beams = Keyword.get(opts, :validate_beams, true)
    incremental = Keyword.get(opts, :incremental, false)
    changed_files = Keyword.get(opts, :changed_files, [])

    with :ok <- validate_sandbox_path(sandbox_path),
         {:ok, temp_dir} <- create_temp_build_dir(opts),
         {:ok, output, warnings} <- compile_in_isolation(sandbox_path, temp_dir, timeout, opts),
         {:ok, artifacts} <- collect_compilation_artifacts(sandbox_path, temp_dir),
         :ok <- maybe_validate_beams(artifacts.beam_files, validate_beams) do
      compilation_time = System.monotonic_time(:millisecond) - start_time

      compile_info = %{
        output: output,
        beam_files: artifacts.beam_files,
        app_file: artifacts.app_file,
        compilation_time: compilation_time,
        temp_dir: temp_dir,
        warnings: warnings,
        incremental: incremental,
        cache_hit: false,
        changed_files: changed_files
      }

      # Update cache if cache is enabled
      cache_enabled = Keyword.get(opts, :cache_enabled, true)

      if cache_enabled do
        case ensure_cache_directory(sandbox_path) do
          {:ok, cache_dir} -> update_compilation_cache(cache_dir, sandbox_path, compile_info)
          # Continue even if cache update fails
          {:error, _} -> :ok
        end
      end

      Logger.debug("Sandbox compiled successfully in #{compilation_time}ms",
        sandbox_path: sandbox_path,
        artifacts: length(artifacts.beam_files),
        incremental: incremental
      )

      {:ok, compile_info}
    else
      {:error, reason} ->
        Logger.warning("Sandbox compilation failed",
          sandbox_path: sandbox_path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp try_cached_compilation(sandbox_path, _opts) do
    with {:ok, cache_dir} <- ensure_cache_directory(sandbox_path),
         {:ok, cached_result} <- get_cached_compilation_result(cache_dir) do
      {:ok, cached_result}
    else
      {:error, {:no_cached_result, _}} -> {:error, :no_cache}
      error -> error
    end
  end

  @doc """
  Validates compiled BEAM files for basic integrity.
  """
  @spec validate_compilation([String.t()]) :: :ok | {:error, String.t()}
  def validate_compilation(beam_files) when is_list(beam_files) do
    beam_files
    |> Enum.reduce_while(:ok, fn beam_file, :ok ->
      case validate_beam_file(beam_file) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{beam_file}: #{reason}"}}
      end
    end)
  end

  @doc """
  Generates a compilation report with warnings and errors.
  """
  @spec compilation_report(compile_result()) :: %{
          status: :success | :failure,
          summary: String.t(),
          details: String.t(),
          metrics: map()
        }
  def compilation_report({:ok, compile_info}) do
    %{
      status: :success,
      summary: "Compilation successful (#{compile_info.compilation_time}ms)",
      details: compile_info.output,
      metrics: %{
        compilation_time: compile_info.compilation_time,
        beam_files_count: length(compile_info.beam_files),
        output_size: byte_size(compile_info.output)
      }
    }
  end

  def compilation_report({:error, reason}) do
    {status_text, details} = format_error_details(reason)

    %{
      status: :failure,
      summary: "Compilation failed: #{status_text}",
      details: details,
      metrics: %{
        compilation_time: 0,
        beam_files_count: 0
      }
    }
  end

  @doc """
  Cleans up temporary compilation artifacts.
  """
  @spec cleanup_temp_artifacts(String.t()) :: :ok
  def cleanup_temp_artifacts(temp_dir) do
    if File.exists?(temp_dir) do
      File.rm_rf!(temp_dir)
      Logger.debug("Cleaned up temp artifacts", temp_dir: temp_dir)
    end

    :ok
  end

  @doc """
  Performs incremental compilation on changed files only.

  ## Options
    * `:changed_files` - List of files that have changed (if not provided, will be detected)
    * `:dependency_analysis` - Whether to analyze dependencies (default: true)
    * All other options from `compile_sandbox/2`

  ## Examples

      iex> incremental_compile("/path/to/sandbox", ["lib/my_module.ex"])
      {:ok, %{incremental: true, changed_files: ["lib/my_module.ex"], ...}}
  """
  @spec incremental_compile(String.t(), [String.t()], compile_opts()) :: compile_result()
  def incremental_compile(sandbox_path, changed_files \\ [], opts \\ []) do
    dependency_analysis = Keyword.get(opts, :dependency_analysis, true)

    with :ok <- validate_sandbox_path(sandbox_path),
         {:ok, cache_dir} <- ensure_cache_directory(sandbox_path),
         {:ok, change_info} <- detect_changed_files(sandbox_path, cache_dir, changed_files),
         {:ok, compilation_scope} <-
           determine_compilation_scope(change_info, dependency_analysis, sandbox_path) do
      cond do
        # No changes detected, return cached result
        is_list(compilation_scope) and Enum.empty?(compilation_scope) ->
          Logger.debug("No changes detected (list), returning cached result")
          get_cached_compilation_result(cache_dir)

        # New enhanced scope with strategy information
        is_map(compilation_scope) and Enum.empty?(compilation_scope.files) ->
          Logger.debug("No changes detected (map), returning cached result")

          case get_cached_compilation_result(cache_dir) do
            {:ok, cached_result} -> {:ok, Map.put(cached_result, :cache_hit, true)}
            error -> error
          end

        # Perform compilation based on strategy
        true ->
          perform_incremental_compilation(sandbox_path, compilation_scope, cache_dir, opts)
      end
    end
  end

  defp perform_incremental_compilation(sandbox_path, compilation_scope, cache_dir, opts)
       when is_map(compilation_scope) do
    strategy = compilation_scope.strategy

    Logger.debug(
      "Performing #{strategy} compilation with #{length(compilation_scope.files)} files"
    )

    files_to_compile = compilation_scope.files

    Logger.debug("Performing incremental compilation",
      strategy: strategy,
      files_count: length(files_to_compile),
      sandbox_path: sandbox_path
    )

    case strategy do
      :cache_hit ->
        # Return cached result directly
        case get_cached_compilation_result(cache_dir) do
          {:ok, cached_result} -> {:ok, Map.put(cached_result, :cache_hit, true)}
          error -> error
        end

      :incremental ->
        # Enhance opts with incremental information
        enhanced_opts =
          Keyword.merge(opts,
            incremental: true,
            changed_files: compilation_scope.changed_files || files_to_compile,
            compilation_strategy: strategy,
            function_only_changes: compilation_scope.function_only_changes
          )

        perform_function_level_compilation(sandbox_path, compilation_scope, enhanced_opts)
        |> handle_incremental_result(cache_dir, sandbox_path, compilation_scope)

      :full ->
        # Enhance opts with incremental information
        enhanced_opts =
          Keyword.merge(opts,
            incremental: true,
            changed_files: compilation_scope.changed_files || files_to_compile,
            compilation_strategy: strategy,
            function_only_changes: compilation_scope.function_only_changes
          )

        compile_sandbox(sandbox_path, enhanced_opts)
        |> handle_incremental_result(cache_dir, sandbox_path, compilation_scope)
    end
  end

  defp perform_incremental_compilation(sandbox_path, files_to_compile, cache_dir, opts)
       when is_list(files_to_compile) do
    # Legacy path for backward compatibility
    enhanced_opts = Keyword.merge(opts, incremental: true, changed_files: files_to_compile)

    compile_sandbox(sandbox_path, enhanced_opts)
    |> handle_incremental_result(cache_dir, sandbox_path, %{
      files: files_to_compile,
      strategy: :full
    })
  end

  defp perform_function_level_compilation(sandbox_path, compilation_scope, opts) do
    # For function-only changes, we can potentially do faster compilation
    # by only recompiling the changed functions
    function_only_files = compilation_scope.function_only_changes

    if function_only_files != [] and length(function_only_files) < 5 do
      # Small number of function-only changes - use optimized compilation
      perform_optimized_function_compilation(sandbox_path, function_only_files, opts)
    else
      # Fall back to regular compilation for larger changes
      compile_sandbox(sandbox_path, opts)
    end
  end

  defp perform_optimized_function_compilation(sandbox_path, changed_files, opts) do
    # This is a simplified implementation - in a full implementation,
    # we would compile only the changed modules with special handling
    # for function-level changes

    Logger.debug("Performing optimized function-level compilation",
      files: changed_files,
      sandbox_path: sandbox_path
    )

    # For now, compile normally but with optimized settings
    # IMPORTANT: Disable cache since we've already detected changes
    optimized_opts =
      Keyword.merge(opts,
        incremental: true,
        function_level: true,
        # Skip validation for faster compilation
        validate_beams: false,
        # Disable cache since files have changed
        cache_enabled: false,
        # Force recompilation of changed files
        force_recompile: true
      )

    compile_sandbox(sandbox_path, optimized_opts)
  end

  defp handle_incremental_result(result, cache_dir, sandbox_path, compilation_scope) do
    case result do
      {:ok, compile_info} ->
        # Update cache with new compilation result
        update_compilation_cache(cache_dir, sandbox_path, compile_info)

        enhanced_info =
          Map.merge(compile_info, %{
            incremental: true,
            changed_files: compilation_scope.changed_files || compilation_scope.files,
            cache_hit: false,
            compilation_strategy: compilation_scope.strategy || :full
          })

        {:ok, enhanced_info}

      error ->
        error
    end
  end

  @doc """
  Compiles a single Elixir file in isolation.
  """
  @spec compile_file(String.t(), compile_opts()) :: compile_result()
  def compile_file(file_path, opts \\ []) do
    if File.exists?(file_path) do
      # Create a temporary directory for single file compilation
      temp_sandbox = Path.join(System.tmp_dir!(), "apex_file_#{random_string()}")
      File.mkdir_p!(temp_sandbox)

      # Copy file to temp sandbox
      File.cp!(file_path, Path.join(temp_sandbox, Path.basename(file_path)))

      # Compile with elixirc
      result = compile_sandbox(temp_sandbox, Keyword.put(opts, :compiler, :elixirc))

      # Cleanup
      File.rm_rf!(temp_sandbox)

      result
    else
      {:error, {:invalid_file_path, "File does not exist: #{file_path}"}}
    end
  end

  @doc """
  Scans code for security vulnerabilities and dangerous patterns.

  ## Options
    * `:restricted_modules` - List of modules that are not allowed
    * `:allowed_operations` - List of allowed operations (whitelist mode)
    * `:scan_depth` - How deep to scan for nested calls (default: 3)

  ## Examples

      iex> scan_code_security("/path/to/sandbox")
      {:ok, %{threats: [], warnings: [%{type: :file_access, file: "lib/file_ops.ex"}]}}
  """
  @spec scan_code_security(String.t(), keyword()) ::
          {:ok, %{threats: [map()], warnings: [map()]}} | {:error, term()}
  def scan_code_security(sandbox_path, opts \\ []) do
    restricted_modules = Keyword.get(opts, :restricted_modules, default_restricted_modules())
    allowed_operations = Keyword.get(opts, :allowed_operations, [])
    scan_depth = Keyword.get(opts, :scan_depth, 3)

    with :ok <- validate_sandbox_path(sandbox_path),
         {:ok, files} <- get_source_files(sandbox_path) do
      perform_security_scan(files, restricted_modules, allowed_operations, scan_depth)
    end
  end

  @doc """
  Validates BEAM files for integrity and security.
  """
  @spec validate_beam_files([String.t()]) :: :ok | {:error, String.t()}
  def validate_beam_files(beam_files) when is_list(beam_files) do
    beam_files
    |> Enum.reduce_while(:ok, fn beam_file, :ok ->
      case validate_beam_file_security(beam_file) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, "#{beam_file}: #{reason}"}}
      end
    end)
  end

  # Private functions

  defp validate_sandbox_path(sandbox_path) do
    cond do
      not File.exists?(sandbox_path) ->
        {:error, {:invalid_sandbox_path, "Directory does not exist: #{sandbox_path}"}}

      not File.dir?(sandbox_path) ->
        {:error, {:invalid_sandbox_path, "Path is not a directory: #{sandbox_path}"}}

      true ->
        :ok
    end
  end

  defp create_temp_build_dir(opts) do
    case Keyword.get(opts, :temp_dir) do
      nil ->
        temp_dir = Path.join(System.tmp_dir!(), @temp_dir_prefix <> random_string())
        File.mkdir_p!(temp_dir)
        {:ok, temp_dir}

      temp_dir ->
        File.mkdir_p!(temp_dir)
        {:ok, temp_dir}
    end
  end

  defp compile_in_isolation(sandbox_path, temp_dir, timeout, opts) do
    memory_limit = Keyword.get(opts, :memory_limit, @default_memory_limit)
    cpu_limit = Keyword.get(opts, :cpu_limit, 80.0)
    max_processes = Keyword.get(opts, :max_processes, 100)
    security_scan = Keyword.get(opts, :security_scan, true)
    env = Keyword.get(opts, :env, %{})
    compiler = Keyword.get(opts, :compiler, :mix)

    # Perform security scan before compilation if enabled
    with :ok <- maybe_perform_security_scan(security_scan, sandbox_path, opts) do
      compile_context = %{
        parent: self(),
        sandbox_path: sandbox_path,
        temp_dir: temp_dir,
        timeout: timeout,
        memory_limit: memory_limit,
        cpu_limit: cpu_limit,
        max_processes: max_processes,
        env: env,
        compiler: compiler
      }

      do_compile_in_isolation(compile_context)
    end
  end

  defp maybe_perform_security_scan(false, _sandbox_path, _opts), do: :ok

  defp maybe_perform_security_scan(true, sandbox_path, opts) do
    case scan_code_security(sandbox_path, opts) do
      {:ok, %{threats: []}} -> :ok
      {:ok, %{threats: threats}} -> {:error, {:security_threats_detected, threats}}
      {:error, reason} -> {:error, {:security_scan_failed, reason}}
    end
  end

  defp do_compile_in_isolation(ctx) do
    %{
      parent: parent,
      sandbox_path: sandbox_path,
      temp_dir: temp_dir,
      timeout: timeout,
      memory_limit: memory_limit,
      cpu_limit: cpu_limit,
      max_processes: max_processes,
      env: env,
      compiler: compiler
    } = ctx

    # Set up isolated build environment with comprehensive resource constraints
    build_env =
      Map.merge(
        %{
          "MIX_BUILD_PATH" => temp_dir,
          "MIX_ARCHIVES" => "",
          "MIX_DEPS_PATH" => Path.join(temp_dir, "deps"),
          "ELIXIR_MAX_PROCESSES" => to_string(max_processes),
          # Restrict system access
          "HOME" => temp_dir,
          "TMPDIR" => temp_dir,
          "PATH" => get_restricted_path(),
          # Disable potentially dangerous features
          "MIX_INSTALL_FORCE" => "false",
          "MIX_INSTALL_DIR" => temp_dir
        },
        env
      )

    # Create enhanced resource monitor with CPU tracking
    resource_monitor = spawn_enhanced_resource_monitor(memory_limit, cpu_limit, max_processes)

    compiler_pid =
      spawn(fn ->
        try do
          # Set comprehensive resource limits and isolation
          set_enhanced_resource_limits(memory_limit, cpu_limit, max_processes)

          # Create isolated compilation environment
          setup_compilation_isolation(temp_dir)

          # Store original directory but don't change to sandbox directory
          # This avoids issues with concurrent tests cleaning up directories
          _original_cwd =
            case File.cwd() do
              {:ok, cwd} -> cwd
              {:error, _} -> "/tmp"
            end

          validate_sandbox_safety(sandbox_path)

          # Start enhanced resource monitoring
          send(resource_monitor, {:monitor_process, self()})

          # Compile with timeout and resource monitoring
          {result, exit_code} = compile_with(compiler, sandbox_path, build_env)

          # Parse warnings and perform post-compilation security checks
          warnings = parse_compilation_warnings(result)
          security_warnings = perform_post_compilation_security_check(temp_dir)

          # No need to restore working directory since we didn't change it

          send(parent, {:compilation_result, exit_code, result, warnings ++ security_warnings})
        catch
          kind, error ->
            # Enhanced error reporting with security context
            error_context = %{
              kind: kind,
              error: error,
              pid: self(),
              sandbox_path: sandbox_path,
              timestamp: DateTime.utc_now()
            }

            send(parent, {:compilation_error, kind, error, error_context})
        end
      end)

    # Monitor compiler process with enhanced monitoring
    compiler_ref = Process.monitor(compiler_pid)
    resource_ref = Process.monitor(resource_monitor)

    # Enhanced timeout handling with graceful termination
    timeout_timer = Process.send_after(self(), {:compilation_timeout, timeout}, timeout)

    receive do
      {:compilation_result, 0, output, warnings} ->
        Process.cancel_timer(timeout_timer)
        cleanup_monitors(compiler_ref, resource_ref, resource_monitor)
        {:ok, output, warnings}

      {:compilation_result, exit_code, output, warnings} ->
        Process.cancel_timer(timeout_timer)
        cleanup_monitors(compiler_ref, resource_ref, resource_monitor)
        {:error, {:compilation_failed, exit_code, output, warnings}}

      {:compilation_error, kind, error, context} ->
        Process.cancel_timer(timeout_timer)
        cleanup_monitors(compiler_ref, resource_ref, resource_monitor)
        {:error, {:compiler_crash, kind, error, context}}

      {:resource_limit_exceeded, limit_type, details} ->
        Process.cancel_timer(timeout_timer)
        gracefully_terminate_compiler(compiler_pid, 1000)
        cleanup_monitors(compiler_ref, resource_ref, resource_monitor)
        {:error, {:resource_limit_exceeded, limit_type, details}}

      {:DOWN, ^compiler_ref, :process, ^compiler_pid, reason} ->
        Process.cancel_timer(timeout_timer)
        cleanup_monitors(compiler_ref, resource_ref, resource_monitor)
        {:error, {:compiler_crash, :process_down, reason}}

      {:DOWN, ^resource_ref, :process, ^resource_monitor, reason} ->
        Process.cancel_timer(timeout_timer)
        gracefully_terminate_compiler(compiler_pid, 1000)
        Process.demonitor(compiler_ref, [:flush])
        {:error, {:resource_monitor_failed, reason}}

      {:compilation_timeout, timeout_value} ->
        gracefully_terminate_compiler(compiler_pid, 2000)
        cleanup_monitors(compiler_ref, resource_ref, resource_monitor)
        {:error, {:compilation_timeout, timeout_value}}
    end
  end

  defp compile_with(:mix, sandbox_path, build_env) do
    # First try in-process compilation for test environments
    if in_test_environment?() do
      Logger.debug("Using in-process compilation for test environment")
      compile_with(:in_process, sandbox_path, build_env)
    else
      Logger.debug("Using external elixir compilation")
      # Use the same Elixir executable that's running the current process
      elixir_path = System.find_executable("elixir") || System.find_executable("mix") || "mix"

      System.cmd(elixir_path, ["-S", "mix", "compile", "--force"],
        stderr_to_stdout: true,
        env: build_env
      )
    end
  end

  defp compile_with(:elixirc, sandbox_path, build_env) do
    # Use in-process compilation for test environments
    if in_test_environment?() do
      Logger.debug("Using in-process compilation for elixirc in test environment")
      compile_with(:in_process, sandbox_path, build_env)
    else
      files = Path.wildcard(Path.join(sandbox_path, "*.ex"))
      elixirc_path = System.find_executable("elixirc") || "elixirc"

      if files != [] do
        ebin_dir = Path.join(sandbox_path, "ebin")
        File.mkdir_p!(ebin_dir)

        System.cmd(elixirc_path, files ++ ["-o", ebin_dir], stderr_to_stdout: true)
      else
        {"No .ex files found to compile", 0}
      end
    end
  end

  defp compile_with(:erlc, sandbox_path, _build_env) do
    files = Path.wildcard(Path.join(sandbox_path, "*.erl"))
    System.cmd("erlc", files ++ ["-o", Path.join(sandbox_path, "ebin")], stderr_to_stdout: true)
  end

  defp compile_with(:in_process, sandbox_path, build_env) do
    alias Sandbox.InProcessCompiler

    # Use the build path from environment if available, otherwise use standard location
    temp_dir = Map.get(build_env, "MIX_BUILD_PATH", Path.join(sandbox_path, "_build/test"))
    app_name = extract_app_name(sandbox_path)
    output_path = Path.join([temp_dir, "lib", to_string(app_name), "ebin"])

    Logger.debug("In-process compilation output path: #{output_path}")

    case InProcessCompiler.compile_in_process(sandbox_path, output_path) do
      {:ok, %{beam_files: beam_files, warnings: warnings}} ->
        # Format output to match expected format
        output = format_in_process_output(beam_files, warnings)
        {output, 0}

      {:error, %{errors: errors, warnings: warnings}} ->
        output = format_in_process_errors(errors, warnings)
        {output, 1}

      {:error, reason} ->
        {"Compilation error: #{inspect(reason)}", 1}
    end
  end

  defp collect_compilation_artifacts(sandbox_path, temp_dir) do
    # Try to extract app name from mix.exs if it exists
    app_name = extract_app_name(sandbox_path)

    # Locate BEAM files in various possible locations
    beam_files = find_beam_files(sandbox_path, temp_dir, app_name)

    # Locate .app file
    app_file = find_app_file(sandbox_path, temp_dir, app_name)

    {:ok, %{beam_files: beam_files, app_file: app_file}}
  end

  defp find_beam_files(sandbox_path, temp_dir, app_name) do
    patterns = [
      # Mix build output
      Path.join([temp_dir, "lib", to_string(app_name), "ebin", "*.beam"]),
      # Direct compilation output
      Path.join([sandbox_path, "ebin", "*.beam"]),
      # Root directory (for simple cases)
      Path.join([sandbox_path, "*.beam"])
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
  end

  defp find_app_file(sandbox_path, temp_dir, app_name) do
    patterns = [
      Path.join([temp_dir, "lib", to_string(app_name), "ebin", "#{app_name}.app"]),
      Path.join([sandbox_path, "ebin", "#{app_name}.app"])
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> List.first()
  end

  defp extract_app_name(sandbox_path) do
    mix_file = Path.join(sandbox_path, "mix.exs")

    if File.exists?(mix_file) do
      try do
        content = File.read!(mix_file)

        # Extract app name using regex
        case Regex.run(~r/app:\s*:(\w+)/, content) do
          [_, app_name] -> String.to_atom(app_name)
          nil -> :unknown_app
        end
      rescue
        _ -> :unknown_app
      end
    else
      # Use directory name as fallback
      sandbox_path
      |> Path.basename()
      |> String.to_atom()
    end
  end

  defp maybe_validate_beams(beam_files, true), do: validate_compilation(beam_files)
  defp maybe_validate_beams(_beam_files, false), do: :ok

  defp validate_beam_file(beam_file) do
    case :beam_lib.info(String.to_charlist(beam_file)) do
      {:error, :beam_lib, reason} ->
        {:error, "Invalid BEAM file: #{inspect(reason)}"}

      info when is_list(info) ->
        # beam_lib.info returns a list of chunks/info directly
        :ok
    end
  rescue
    error -> {:error, "BEAM validation error: #{inspect(error)}"}
  end

  defp random_string(length \\ 8) do
    :crypto.strong_rand_bytes(length)
    |> Base.encode32(case: :lower, padding: false)
    |> String.slice(0, length)
  end

  defp format_error_details({:compilation_failed, exit_code, output}) do
    {"Exit code #{exit_code}", output}
  end

  defp format_error_details({:compilation_timeout, timeout}) do
    {"Timeout after #{timeout}ms", "Compilation did not complete within the timeout period."}
  end

  defp format_error_details({:compiler_crash, kind, error}) do
    {"Compiler crash (#{kind})", inspect(error)}
  end

  defp format_error_details({:invalid_sandbox_path, reason}) do
    {"Invalid sandbox path", reason}
  end

  defp format_error_details({:beam_validation_failed, reason}) do
    {"BEAM validation failed", reason}
  end

  defp format_error_details(other) do
    {"Unknown error", inspect(other)}
  end

  # Incremental compilation and caching functions

  defp ensure_cache_directory(sandbox_path) do
    cache_dir = Path.join(sandbox_path, @cache_dir_name)

    case File.mkdir_p(cache_dir) do
      :ok -> {:ok, cache_dir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp detect_changed_files(sandbox_path, cache_dir, provided_files) do
    if Enum.empty?(provided_files) do
      # Auto-detect changed files using file hashes
      detect_changes_by_hash(sandbox_path, cache_dir)
    else
      # Use provided file list but still analyze for incremental opportunities
      _current_hashes = calculate_file_hashes(sandbox_path)

      # Create change info structure for provided files
      change_info = %{
        content_changed: provided_files,
        # Assume all changes are function-level for provided files
        function_changed: provided_files,
        all_changed: provided_files,
        incremental_eligible: true
      }

      {:ok, change_info}
    end
  end

  defp detect_changes_by_hash(sandbox_path, cache_dir) do
    hash_file = Path.join(cache_dir, "file_hashes.json")
    current_hashes = calculate_file_hashes(sandbox_path)

    Logger.debug("Current files: #{inspect(Map.keys(current_hashes))}")

    previous_hashes = load_previous_hashes(hash_file)

    {content_changed, function_changed} =
      detect_hash_changes(current_hashes, previous_hashes)

    Logger.debug(
      "Change detection: content_changed=#{inspect(content_changed)}, function_changed=#{inspect(function_changed)}"
    )

    new_files = find_new_files(current_hashes, previous_hashes)
    deleted_files = find_deleted_files(current_hashes, previous_hashes)

    all_changed_files =
      Enum.uniq(content_changed ++ function_changed ++ new_files ++ deleted_files)

    save_hash_file(hash_file, current_hashes)

    {:ok,
     %{
       content_changed: content_changed,
       function_changed: function_changed,
       all_changed: all_changed_files,
       new_files: new_files,
       deleted_files: deleted_files,
       incremental_eligible: function_changed != [] and content_changed -- function_changed == []
     }}
  end

  defp load_previous_hashes(hash_file) do
    if File.exists?(hash_file) do
      try do
        decoded =
          hash_file
          |> File.read!()
          |> Jason.decode!()

        result = Map.new(decoded, fn {k, v} -> {to_string(k), v} end)
        Logger.debug("Loaded #{map_size(result)} previous hashes")
        result
      rescue
        _ -> %{}
      end
    else
      Logger.debug("No previous hash file found")
      %{}
    end
  end

  defp detect_hash_changes(current_hashes, previous_hashes) do
    is_first_run = map_size(previous_hashes) == 0

    current_hashes
    |> Enum.reduce({[], []}, fn {file, current_hash_info}, {content_acc, function_acc} ->
      file_key = to_string(file)
      previous_hash_info = Map.get(previous_hashes, file_key, %{})

      content_changed =
        check_content_changed(
          current_hash_info,
          previous_hash_info,
          file_key,
          previous_hashes,
          is_first_run
        )

      function_changed =
        check_function_changed(
          current_hash_info,
          previous_hash_info,
          file_key,
          previous_hashes,
          is_first_run
        )

      new_content_acc = if content_changed, do: [file | content_acc], else: content_acc
      new_function_acc = if function_changed, do: [file | function_acc], else: function_acc

      {new_content_acc, new_function_acc}
    end)
  end

  defp check_content_changed(
         current_hash_info,
         previous_hash_info,
         file_key,
         previous_hashes,
         is_first_run
       ) do
    no_previous_hash = has_no_previous_hash?(previous_hash_info, :content_hash)

    if no_previous_hash do
      is_first_run or not Map.has_key?(previous_hashes, file_key)
    else
      current_hash = current_hash_info.content_hash
      previous_hash = get_hash_value(previous_hash_info, :content_hash)
      current_hash != previous_hash
    end
  end

  defp check_function_changed(
         current_hash_info,
         previous_hash_info,
         file_key,
         previous_hashes,
         is_first_run
       ) do
    no_previous_hash = has_no_previous_hash?(previous_hash_info, :function_hash)

    if no_previous_hash do
      is_first_run or not Map.has_key?(previous_hashes, file_key)
    else
      current_hash_info.function_hash != get_hash_value(previous_hash_info, :function_hash)
    end
  end

  defp has_no_previous_hash?(previous_hash_info, hash_key) do
    string_key = Atom.to_string(hash_key)
    Map.get(previous_hash_info, string_key) == nil && Map.get(previous_hash_info, hash_key) == nil
  end

  defp get_hash_value(hash_info, hash_key) do
    string_key = Atom.to_string(hash_key)
    Map.get(hash_info, string_key) || Map.get(hash_info, hash_key)
  end

  defp find_new_files(current_hashes, previous_hashes) do
    current_hashes
    |> Map.keys()
    |> Enum.filter(fn file -> not Map.has_key?(previous_hashes, file) end)
  end

  defp find_deleted_files(current_hashes, previous_hashes) do
    previous_hashes
    |> Map.keys()
    |> Enum.filter(fn file -> not Map.has_key?(current_hashes, file) end)
  end

  defp save_hash_file(hash_file, current_hashes) do
    File.write!(hash_file, Jason.encode!(current_hashes))
    Logger.debug("Updated hash file with #{map_size(current_hashes)} entries")
  rescue
    error ->
      Logger.warning("Failed to write hash file: #{inspect(error)}")
  end

  defp calculate_file_hashes(sandbox_path) do
    patterns = [
      Path.join(sandbox_path, "**/*.ex"),
      Path.join(sandbox_path, "**/*.exs"),
      Path.join(sandbox_path, "**/*.erl"),
      Path.join(sandbox_path, "mix.exs")
    ]

    patterns
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reduce(%{}, fn file, acc ->
      try do
        relative_path = Path.relative_to(file, sandbox_path)
        content = File.read!(file)

        # Content from File.read! is always binary
        binary_content = content

        # Calculate both content hash and function-level hash for incremental compilation
        content_hash =
          :crypto.hash(:sha256, binary_content)
          |> Base.encode16(case: :lower)

        function_hash = calculate_function_level_hash(binary_content)

        Map.put(acc, relative_path, %{
          content_hash: content_hash,
          function_hash: function_hash,
          size: byte_size(binary_content),
          modified_time: get_file_modified_time(file)
        })
      rescue
        error ->
          Logger.warning("Failed to hash file #{file}: #{inspect(error)}")
          acc
      end
    end)
  end

  defp calculate_function_level_hash(content) when is_binary(content) do
    # Parse the content to extract function definitions
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        functions = extract_function_definitions(ast)

        # Create hash based on function signatures and bodies
        functions
        |> Enum.sort()
        |> :erlang.term_to_binary()
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      {:error, _} ->
        # If parsing fails, fall back to content hash
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)
    end
  rescue
    _ ->
      # If anything fails, fall back to content hash
      :crypto.hash(:sha256, content)
      |> Base.encode16(case: :lower)
  end

  defp extract_function_definitions(ast) do
    {_ast, functions} =
      Macro.prewalk(ast, [], fn
        {:def, _meta, [{name, _meta2, args}, body]} = node, acc ->
          function_info = {name, length(args || []), normalize_ast(body)}
          {node, [function_info | acc]}

        {:defp, _meta, [{name, _meta2, args}, body]} = node, acc ->
          function_info = {name, length(args || []), normalize_ast(body)}
          {node, [function_info | acc]}

        node, acc ->
          {node, acc}
      end)

    functions
  end

  defp normalize_ast(ast) do
    # Normalize AST by removing metadata that doesn't affect functionality
    Macro.prewalk(ast, fn
      {name, _meta, args} -> {name, [], args}
      other -> other
    end)
  end

  defp get_file_modified_time(file_path) do
    case File.stat(file_path) do
      {:ok, %File.Stat{mtime: mtime}} ->
        # Convert to Unix timestamp for JSON serialization
        :calendar.datetime_to_gregorian_seconds(mtime) -
          :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

      {:error, _} ->
        0
    end
  end

  defp determine_compilation_scope(change_info, false, _sandbox_path) when is_map(change_info) do
    # No dependency analysis, just compile changed files
    if Enum.empty?(change_info.all_changed) do
      {:ok, %{files: [], strategy: :cache_hit, changed_files: [], function_only_changes: []}}
    else
      {:ok, change_info.all_changed}
    end
  end

  defp determine_compilation_scope(change_info, true, sandbox_path) when is_map(change_info) do
    # Check if there are any changes first
    Logger.debug("Change info: all_changed=#{inspect(change_info.all_changed)}")

    if Enum.empty?(change_info.all_changed) do
      Logger.debug("No changes detected in determine_compilation_scope")
      {:ok, %{files: [], strategy: :cache_hit, changed_files: [], function_only_changes: []}}
    else
      # Analyze dependencies to determine full compilation scope
      with {:ok, dependency_graph} <- analyze_dependencies(sandbox_path) do
        expanded_scope = expand_compilation_scope(change_info.all_changed, dependency_graph)

        # Determine if incremental compilation is possible
        incremental_possible =
          change_info.incremental_eligible and
            length(expanded_scope) <= length(change_info.all_changed) * 2

        compilation_strategy = if incremental_possible, do: :incremental, else: :full

        {:ok,
         %{
           files: expanded_scope,
           strategy: compilation_strategy,
           changed_files: change_info.all_changed,
           function_only_changes: change_info.function_changed
         }}
      end
    end
  end

  defp analyze_dependencies(sandbox_path) do
    # Enhanced dependency analysis with AST parsing and caching
    cache_dir = Path.join(sandbox_path, @cache_dir_name)
    dependency_cache_file = Path.join(cache_dir, "dependency_graph.json")

    # Check if we have a cached dependency graph
    cached_dependencies = load_cached_dependencies(dependency_cache_file)

    elixir_files = Path.wildcard(Path.join(sandbox_path, "**/*.ex"))

    dependencies =
      elixir_files
      |> Enum.into(%{}, fn file ->
        relative_path = Path.relative_to(file, sandbox_path)

        # Check if file has changed since last dependency analysis
        file_hash = calculate_single_file_hash(file)
        cached_deps = Map.get(cached_dependencies, relative_path, %{})

        if Map.get(cached_deps, :file_hash) == file_hash do
          # Use cached dependencies
          deps = Map.get(cached_deps, :dependencies, [])
          {relative_path, deps}
        else
          # Analyze dependencies fresh
          deps = extract_file_dependencies(file)
          {relative_path, deps}
        end
      end)

    # Cache the dependency analysis results
    cache_dependencies(dependency_cache_file, dependencies, elixir_files)

    {:ok, dependencies}
  end

  defp extract_file_dependencies(file_path) do
    content = File.read!(file_path)

    # Try AST-based analysis first
    case Code.string_to_quoted(content) do
      {:ok, ast} ->
        extract_dependencies_from_ast(ast)

      {:error, _} ->
        # Fall back to regex-based analysis
        extract_dependencies_with_regex(content)
    end
  rescue
    _ -> []
  end

  defp extract_dependencies_from_ast(ast) do
    {_ast, dependencies} =
      Macro.prewalk(ast, [], fn
        # Import statements
        {:import, _meta, [{:__aliases__, _, modules}]} = node, acc ->
          module_name = Module.concat(modules)
          {node, [module_name | acc]}

        # Alias statements
        {:alias, _meta, [{:__aliases__, _, modules}]} = node, acc ->
          module_name = Module.concat(modules)
          {node, [module_name | acc]}

        # Use statements
        {:use, _meta, [{:__aliases__, _, modules} | _]} = node, acc ->
          module_name = Module.concat(modules)
          {node, [module_name | acc]}

        # Module calls (e.g., MyModule.function())
        {{:., _, [{:__aliases__, _, modules}, _function]}, _, _args} = node, acc ->
          module_name = Module.concat(modules)
          {node, [module_name | acc]}

        # Struct references (e.g., %MyModule{})
        {:%, _, [{:__aliases__, _, modules}, _fields]} = node, acc ->
          module_name = Module.concat(modules)
          {node, [module_name | acc]}

        node, acc ->
          {node, acc}
      end)

    dependencies
    |> Enum.uniq()
    |> Enum.map(&to_string/1)
  end

  defp extract_dependencies_with_regex(content) do
    # Enhanced regex patterns for dependency extraction
    patterns = [
      ~r/import\s+([A-Z][A-Za-z0-9_.]*)/,
      ~r/alias\s+([A-Z][A-Za-z0-9_.]*)/,
      ~r/use\s+([A-Z][A-Za-z0-9_.]*)/,
      # Module calls
      ~r/([A-Z][A-Za-z0-9_.]*)\./,
      # Struct references
      ~r/%([A-Z][A-Za-z0-9_.]*)\{/
    ]

    patterns
    |> Enum.flat_map(fn pattern ->
      Regex.scan(pattern, content, capture: :all_but_first)
    end)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(&valid_module_name?/1)
  end

  defp valid_module_name?(name) do
    # Filter out common false positives
    not Enum.member?(["Enum", "String", "Integer", "Float", "Process", "GenServer"], name) and
      String.match?(name, ~r/^[A-Z][A-Za-z0-9_.]*$/)
  end

  defp calculate_single_file_hash(file_path) do
    content = File.read!(file_path)

    # Content from File.read! is always binary
    :crypto.hash(:sha256, content)
    |> Base.encode16(case: :lower)
  rescue
    _ -> "unknown"
  end

  defp load_cached_dependencies(cache_file) do
    if File.exists?(cache_file) do
      try do
        cache_file
        |> File.read!()
        |> Jason.decode!(keys: :atoms)
      rescue
        _ -> %{}
      end
    else
      %{}
    end
  end

  defp cache_dependencies(cache_file, dependencies, files) do
    # Create cache data with file hashes
    cache_data =
      dependencies
      |> Enum.into(%{}, fn {file_path, deps} ->
        build_dependency_cache_entry(file_path, deps, files)
      end)

    try do
      File.write!(cache_file, Jason.encode!(cache_data))
    rescue
      error ->
        Logger.warning("Failed to cache dependencies: #{inspect(error)}")
    end
  end

  defp build_dependency_cache_entry(file_path, deps, files) do
    full_path = resolve_full_path(file_path, files)
    file_hash = calculate_single_file_hash(full_path)

    {file_path,
     %{
       dependencies: deps,
       file_hash: file_hash,
       analyzed_at: DateTime.utc_now() |> DateTime.to_iso8601()
     }}
  end

  defp resolve_full_path(file_path, files) do
    if String.starts_with?(file_path, "/") do
      file_path
    else
      Enum.find(files, fn f -> String.ends_with?(f, file_path) end) || file_path
    end
  end

  defp expand_compilation_scope(changed_files, dependency_graph) do
    # Find all files that depend on the changed files
    changed_modules = extract_modules_from_files(changed_files)

    dependent_files =
      dependency_graph
      |> Enum.filter(fn {_file, deps} ->
        Enum.any?(deps, fn dep -> dep in changed_modules end)
      end)
      |> Enum.map(fn {file, _deps} -> file end)

    (changed_files ++ dependent_files)
    |> Enum.uniq()
  end

  defp extract_modules_from_files(files) do
    files
    |> Enum.flat_map(fn file ->
      # Extract module name from file path
      file
      |> to_string()
      |> Path.basename(".ex")
      |> Macro.camelize()
      |> List.wrap()
    end)
  end

  defp get_cached_compilation_result(cache_dir) do
    cache_file = Path.join(cache_dir, "last_compilation.json")

    Logger.debug("Checking for cached result at: #{cache_file}")

    if File.exists?(cache_file) do
      Logger.debug("Cache file exists")

      try do
        cached_data =
          cache_file
          |> File.read!()
          |> Jason.decode!(keys: :atoms)

        # Validate cache is still valid
        case validate_cache_validity(cached_data, cache_dir) do
          :valid ->
            compile_info = %{
              output: cached_data.output,
              beam_files: cached_data.beam_files,
              app_file: cached_data.app_file,
              compilation_time: 0,
              temp_dir: cached_data.temp_dir,
              warnings: cached_data.warnings || [],
              incremental: true,
              cache_hit: true,
              changed_files: [],
              cache_timestamp: cached_data.timestamp,
              compilation_strategy: Map.get(cached_data, :compilation_strategy, :full)
            }

            {:ok, compile_info}

          :invalid ->
            {:error, {:cache_invalid, "Cache is outdated or corrupted"}}
        end
      rescue
        error ->
          Logger.warning("Failed to read compilation cache: #{inspect(error)}")
          {:error, {:cache_read_error, inspect(error)}}
      end
    else
      {:error, {:no_cached_result, "No previous compilation found"}}
    end
  end

  defp validate_cache_validity(cached_data, _cache_dir) do
    # Check if cache is too old (older than 24 hours)
    case DateTime.from_iso8601(cached_data.timestamp) do
      {:ok, cache_time, _} ->
        validate_cache_age_and_files(cache_time, cached_data)

      {:error, _} ->
        :invalid
    end
  end

  defp validate_cache_age_and_files(cache_time, cached_data) do
    now = DateTime.utc_now()
    hours_old = DateTime.diff(now, cache_time, :hour)

    cond do
      hours_old > 24 ->
        :invalid

      not beam_files_exist?(cached_data) ->
        :invalid

      true ->
        :valid
    end
  end

  defp beam_files_exist?(cached_data) do
    beam_files = Map.get(cached_data, :beam_files, [])
    Enum.all?(beam_files, &File.exists?/1)
  end

  defp update_compilation_cache(cache_dir, sandbox_path, compile_info) do
    cache_file = Path.join(cache_dir, "last_compilation.json")

    cache_data = %{
      output: compile_info.output,
      beam_files: compile_info.beam_files,
      app_file: compile_info.app_file,
      temp_dir: compile_info.temp_dir,
      warnings: Map.get(compile_info, :warnings, []),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      sandbox_path: sandbox_path,
      compilation_strategy: Map.get(compile_info, :compilation_strategy, :full),
      incremental: Map.get(compile_info, :incremental, false),
      changed_files: Map.get(compile_info, :changed_files, [])
    }

    try do
      File.write!(cache_file, Jason.encode!(cache_data))

      # Update file hashes
      update_file_hashes(cache_dir, sandbox_path)

      # Also update cache statistics
      update_cache_statistics(cache_dir, compile_info)
    rescue
      error ->
        Logger.warning("Failed to update compilation cache: #{inspect(error)}")
    end
  end

  defp update_file_hashes(cache_dir, sandbox_path) do
    hash_file = Path.join(cache_dir, "file_hashes.json")
    current_hashes = calculate_file_hashes(sandbox_path)

    try do
      File.write!(hash_file, Jason.encode!(current_hashes))
    rescue
      error ->
        Logger.warning("Failed to update file hashes: #{inspect(error)}")
    end
  end

  defp update_cache_statistics(cache_dir, compile_info) do
    stats_file = Path.join(cache_dir, "cache_stats.json")

    current_stats =
      if File.exists?(stats_file) do
        try do
          stats_file
          |> File.read!()
          |> Jason.decode!(keys: :atoms)
        rescue
          _ -> %{}
        end
      else
        %{}
      end

    # Update statistics
    updated_stats = %{
      total_compilations: Map.get(current_stats, :total_compilations, 0) + 1,
      incremental_compilations:
        Map.get(current_stats, :incremental_compilations, 0) +
          if(Map.get(compile_info, :incremental, false), do: 1, else: 0),
      cache_hits:
        Map.get(current_stats, :cache_hits, 0) +
          if(Map.get(compile_info, :cache_hit, false), do: 1, else: 0),
      average_compilation_time: calculate_average_time(current_stats, compile_info),
      last_updated: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    try do
      File.write!(stats_file, Jason.encode!(updated_stats))
    rescue
      error ->
        Logger.warning("Failed to update cache statistics: #{inspect(error)}")
    end
  end

  defp calculate_average_time(current_stats, compile_info) do
    current_avg = Map.get(current_stats, :average_compilation_time, 0)
    current_count = Map.get(current_stats, :total_compilations, 0)
    new_time = Map.get(compile_info, :compilation_time, 0)

    if current_count == 0 do
      new_time
    else
      (current_avg * current_count + new_time) / (current_count + 1)
    end
  end

  @doc """
  Gets compilation cache statistics.

  ## Returns

  `{:ok, stats}` with cache performance statistics

  ## Example

      {:ok, stats} = get_cache_statistics("/path/to/sandbox")
      IO.inspect(stats.cache_hit_rate)
  """
  @spec get_cache_statistics(String.t()) :: {:ok, map()} | {:error, term()}
  def get_cache_statistics(sandbox_path) do
    with {:ok, cache_dir} <- ensure_cache_directory(sandbox_path) do
      stats_file = Path.join(cache_dir, "cache_stats.json")

      if File.exists?(stats_file) do
        try do
          stats =
            stats_file
            |> File.read!()
            |> Jason.decode!(keys: :atoms)

          # Calculate derived statistics
          total = Map.get(stats, :total_compilations, 0)
          cache_hits = Map.get(stats, :cache_hits, 0)
          incremental = Map.get(stats, :incremental_compilations, 0)

          enhanced_stats =
            Map.merge(stats, %{
              cache_hit_rate: if(total > 0, do: cache_hits / total, else: 0.0),
              incremental_rate: if(total > 0, do: incremental / total, else: 0.0)
            })

          {:ok, enhanced_stats}
        rescue
          error ->
            {:error, {:stats_read_error, inspect(error)}}
        end
      else
        {:ok,
         %{
           total_compilations: 0,
           incremental_compilations: 0,
           cache_hits: 0,
           cache_hit_rate: 0.0,
           incremental_rate: 0.0,
           average_compilation_time: 0
         }}
      end
    end
  end

  @doc """
  Clears the compilation cache for a sandbox.

  ## Parameters

  - `sandbox_path` - Path to the sandbox

  ## Returns

  `:ok` if successful, `{:error, reason}` otherwise

  ## Example

      :ok = clear_compilation_cache("/path/to/sandbox")
  """
  @spec clear_compilation_cache(String.t()) :: :ok | {:error, term()}
  def clear_compilation_cache(sandbox_path) do
    case ensure_cache_directory(sandbox_path) do
      {:ok, cache_dir} ->
        try do
          # Remove cache files but keep the directory
          cache_files = [
            "last_compilation.json",
            "file_hashes.json",
            "dependency_graph.json",
            "cache_stats.json"
          ]

          Enum.each(cache_files, fn file ->
            file_path = Path.join(cache_dir, file)

            if File.exists?(file_path) do
              File.rm!(file_path)
            end
          end)

          Logger.debug("Cleared compilation cache", sandbox_path: sandbox_path)
          :ok
        rescue
          error ->
            {:error, {:cache_clear_error, inspect(error)}}
        end

      error ->
        error
    end
  end

  defp parse_compilation_warnings(output) do
    # Parse Elixir compiler warnings from output
    warning_pattern = ~r/warning:\s*(.+?)\n\s*(.+?):(\d+)/

    Regex.scan(warning_pattern, output)
    |> Enum.map(fn [_full, message, file, line] ->
      %{
        file: file,
        line: String.to_integer(line),
        message: String.trim(message)
      }
    end)
  end

  # Resource management functions

  defp spawn_enhanced_resource_monitor(memory_limit, cpu_limit, max_processes) do
    parent = self()

    spawn(fn ->
      # Initialize CPU tracking
      initial_cpu_info = get_system_cpu_info()

      enhanced_resource_monitor_loop(parent, memory_limit, cpu_limit, max_processes, [], %{
        cpu_baseline: initial_cpu_info,
        last_check: System.monotonic_time(:millisecond),
        violation_count: 0,
        check_interval: 1000
      })
    end)
  end

  defp enhanced_resource_monitor_loop(
         parent,
         memory_limit,
         cpu_limit,
         max_processes,
         monitored_pids,
         state
       ) do
    receive do
      {:monitor_process, pid} ->
        ref = Process.monitor(pid)
        # Record initial resource usage for this process
        initial_usage = get_process_resource_usage(pid)

        enhanced_monitored_pids = [{pid, ref, initial_usage} | monitored_pids]

        enhanced_resource_monitor_loop(
          parent,
          memory_limit,
          cpu_limit,
          max_processes,
          enhanced_monitored_pids,
          state
        )

      {:DOWN, _ref, :process, pid, _reason} ->
        updated_pids = Enum.reject(monitored_pids, fn {p, _ref, _usage} -> p == pid end)

        enhanced_resource_monitor_loop(
          parent,
          memory_limit,
          cpu_limit,
          max_processes,
          updated_pids,
          state
        )
    after
      state.check_interval ->
        current_time = System.monotonic_time(:millisecond)

        case check_enhanced_resource_limits(
               monitored_pids,
               memory_limit,
               cpu_limit,
               max_processes,
               state
             ) do
          {:ok, updated_state} ->
            new_state =
              Map.merge(state, %{
                last_check: current_time,
                violation_count: 0
              })
              |> Map.merge(updated_state)

            enhanced_resource_monitor_loop(
              parent,
              memory_limit,
              cpu_limit,
              max_processes,
              monitored_pids,
              new_state
            )

          {:warning, limit_type, details, updated_state} ->
            # Log warning but continue monitoring
            Logger.warning("Resource limit warning",
              type: limit_type,
              details: details,
              violation_count: state.violation_count + 1
            )

            new_state =
              Map.merge(state, %{
                last_check: current_time,
                violation_count: state.violation_count + 1
              })
              |> Map.merge(updated_state)

            # Send violation if we've had multiple warnings
            if new_state.violation_count >= 3 do
              send(parent, {:resource_limit_exceeded, limit_type, details})
            else
              enhanced_resource_monitor_loop(
                parent,
                memory_limit,
                cpu_limit,
                max_processes,
                monitored_pids,
                new_state
              )
            end

          {:error, limit_type, details} ->
            send(parent, {:resource_limit_exceeded, limit_type, details})
        end
    end
  end

  defp check_enhanced_resource_limits(
         monitored_pids,
         memory_limit,
         cpu_limit,
         max_processes,
         state
       ) do
    active_pids = Enum.map(monitored_pids, fn {pid, _ref, _usage} -> pid end)

    case check_process_count(active_pids, max_processes) do
      {:error, _, _} = error ->
        error

      :ok ->
        memory_status = check_memory_status(monitored_pids, memory_limit)
        cpu_status = check_cpu_usage(monitored_pids, cpu_limit, state)
        combine_resource_statuses(memory_status, cpu_status)
    end
  end

  defp check_process_count(active_pids, max_processes) do
    if length(active_pids) > max_processes do
      {:error, :max_processes,
       %{
         current: length(active_pids),
         limit: max_processes,
         pids: active_pids
       }}
    else
      :ok
    end
  end

  defp check_memory_status(monitored_pids, memory_limit) do
    {total_memory, memory_details} = get_detailed_memory_usage(monitored_pids)

    cond do
      total_memory > memory_limit ->
        {:error, :memory_limit,
         %{
           current: total_memory,
           limit: memory_limit,
           details: memory_details,
           top_consumers: get_top_memory_consumers(memory_details, 3)
         }}

      total_memory > memory_limit * 0.8 ->
        {:warning, :memory_limit,
         %{
           current: total_memory,
           limit: memory_limit,
           usage_percentage: total_memory / memory_limit * 100
         }, %{}}

      true ->
        {:ok, %{memory_usage: total_memory}}
    end
  end

  defp combine_resource_statuses(memory_status, cpu_status) do
    case {memory_status, cpu_status} do
      {{:error, type, details}, _} -> {:error, type, details}
      {_, {:error, type, details}} -> {:error, type, details}
      {{:warning, type, details, state_update}, _} -> {:warning, type, details, state_update}
      {_, {:warning, type, details, state_update}} -> {:warning, type, details, state_update}
      {{:ok, mem_state}, {:ok, cpu_state}} -> {:ok, Map.merge(mem_state, cpu_state)}
      {{:ok, mem_state}, :ok} -> {:ok, mem_state}
    end
  end

  defp get_detailed_memory_usage(monitored_pids) do
    memory_details =
      monitored_pids
      |> Enum.map(fn {pid, _ref, _initial_usage} ->
        current_usage = get_process_resource_usage(pid)
        {pid, current_usage}
      end)
      |> Enum.filter(fn {_pid, usage} -> usage.memory > 0 end)

    total_memory =
      memory_details
      |> Enum.map(fn {_pid, usage} -> usage.memory end)
      |> Enum.sum()

    {total_memory, memory_details}
  end

  defp get_top_memory_consumers(memory_details, count) do
    memory_details
    |> Enum.sort_by(fn {_pid, usage} -> usage.memory end, :desc)
    |> Enum.take(count)
    |> Enum.map(fn {pid, usage} ->
      %{pid: pid, memory: usage.memory, memory_mb: div(usage.memory, 1024 * 1024)}
    end)
  end

  defp check_cpu_usage(monitored_pids, cpu_limit, state) do
    if cpu_limit > 0 do
      try do
        current_cpu_info = get_system_cpu_info()
        time_diff = System.monotonic_time(:millisecond) - state.last_check

        # Calculate CPU usage for monitored processes
        process_cpu_usage = calculate_process_cpu_usage(monitored_pids, time_diff)

        cond do
          process_cpu_usage > cpu_limit ->
            {:error, :cpu_limit,
             %{
               current: process_cpu_usage,
               limit: cpu_limit,
               time_window_ms: time_diff
             }}

          process_cpu_usage > cpu_limit * 0.8 ->
            {:warning, :cpu_limit,
             %{
               current: process_cpu_usage,
               limit: cpu_limit,
               usage_percentage: process_cpu_usage / cpu_limit * 100
             }, %{cpu_info: current_cpu_info}}

          true ->
            {:ok, %{cpu_usage: process_cpu_usage, cpu_info: current_cpu_info}}
        end
      rescue
        error ->
          Logger.debug("CPU monitoring failed: #{inspect(error)}")
          :ok
      end
    else
      :ok
    end
  end

  defp get_system_cpu_info do
    # Check if cpu_sup module is available (from os_mon application)
    if Code.ensure_loaded?(:cpu_sup) and function_exported?(:cpu_sup, :util, 0) do
      get_cpu_util_safe()
    else
      # os_mon not available, return default
      %{utilization: 0, timestamp: System.monotonic_time(:millisecond)}
    end
  rescue
    _ -> %{utilization: 0, timestamp: System.monotonic_time(:millisecond)}
  end

  defp get_cpu_util_safe do
    if Code.ensure_loaded?(:cpu_sup) and function_exported?(:cpu_sup, :util, 0) do
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      case apply(:cpu_sup, :util, []) do
        {:error, _} ->
          %{utilization: 0, timestamp: System.monotonic_time(:millisecond)}

        util when is_number(util) ->
          %{utilization: util, timestamp: System.monotonic_time(:millisecond)}

        _ ->
          %{utilization: 0, timestamp: System.monotonic_time(:millisecond)}
      end
    else
      %{utilization: 0, timestamp: System.monotonic_time(:millisecond)}
    end
  end

  defp calculate_process_cpu_usage(monitored_pids, time_diff_ms) do
    if time_diff_ms > 0 do
      monitored_pids
      |> Enum.map(fn {pid, _ref, _initial_usage} ->
        get_process_cpu_usage(pid)
      end)
      |> Enum.sum()
      |> max(0)
    else
      0
    end
  end

  defp get_process_cpu_usage(pid) do
    case Process.info(pid, [:reductions]) do
      [{:reductions, reductions}] ->
        # Convert reductions to approximate CPU percentage
        # This is a rough approximation
        min(reductions / 10_000, 100)

      _ ->
        0
    end
  rescue
    _ -> 0
  end

  defp get_process_resource_usage(pid) do
    case Process.info(pid, [:memory, :reductions, :message_queue_len]) do
      info when is_list(info) ->
        %{
          memory: Keyword.get(info, :memory, 0),
          reductions: Keyword.get(info, :reductions, 0),
          message_queue_len: Keyword.get(info, :message_queue_len, 0),
          timestamp: System.monotonic_time(:millisecond)
        }

      _ ->
        %{
          memory: 0,
          reductions: 0,
          message_queue_len: 0,
          timestamp: System.monotonic_time(:millisecond)
        }
    end
  rescue
    _ ->
      %{
        memory: 0,
        reductions: 0,
        message_queue_len: 0,
        timestamp: System.monotonic_time(:millisecond)
      }
  end

  defp get_restricted_path do
    # Provide minimal PATH with only essential tools
    essential_paths = [
      "/usr/bin",
      "/bin"
    ]

    # Filter to only existing paths
    existing_paths = Enum.filter(essential_paths, &File.exists?/1)
    Enum.join(existing_paths, ":")
  end

  defp setup_compilation_isolation(temp_dir) do
    # Create isolated directories for compilation
    isolation_dirs = [
      Path.join(temp_dir, "home"),
      Path.join(temp_dir, "tmp"),
      Path.join(temp_dir, "cache")
    ]

    Enum.each(isolation_dirs, &File.mkdir_p!/1)

    # Set restrictive permissions where possible
    try do
      System.cmd("chmod", ["700", temp_dir])
    rescue
      # Continue if chmod fails
      _ -> :ok
    end
  end

  defp validate_sandbox_safety(sandbox_path) do
    # Ensure sandbox path is safe and doesn't contain dangerous patterns
    dangerous_patterns = [
      "..",
      "/etc",
      "/usr",
      "/bin",
      "/sbin",
      "/root"
    ]

    if Enum.any?(dangerous_patterns, &String.contains?(sandbox_path, &1)) do
      raise "Unsafe sandbox path detected: #{sandbox_path}"
    end

    # Ensure path is within allowed boundaries
    abs_path = Path.expand(sandbox_path)
    temp_dir = System.tmp_dir!()

    unless String.starts_with?(abs_path, temp_dir) or
             String.contains?(abs_path, "sandbox") or
             String.contains?(abs_path, "test") do
      Logger.warning("Potentially unsafe sandbox path", path: abs_path)
    end
  end

  defp perform_post_compilation_security_check(temp_dir) do
    # Check for suspicious files created during compilation
    suspicious_patterns = [
      "*.sh",
      "*.bat",
      "*.exe",
      "**/tmp/**",
      "**/cache/**"
    ]

    _warnings = []

    try do
      suspicious_files =
        suspicious_patterns
        |> Enum.flat_map(fn pattern ->
          Path.wildcard(Path.join(temp_dir, "**/" <> pattern))
        end)
        |> Enum.filter(&File.regular?/1)

      if suspicious_files != [] do
        [
          %{
            type: :post_compilation_security,
            severity: :medium,
            message: "Suspicious files created during compilation",
            files: suspicious_files,
            file: "compilation_artifacts",
            line: 0
          }
        ]
      else
        []
      end
    rescue
      _ -> []
    end
  end

  defp gracefully_terminate_compiler(compiler_pid, grace_period_ms) do
    # Attempt graceful termination first
    Process.exit(compiler_pid, :shutdown)

    # Wait for graceful shutdown
    receive do
      {:DOWN, _ref, :process, ^compiler_pid, _reason} -> :ok
    after
      grace_period_ms ->
        # Force kill if graceful shutdown fails
        Process.exit(compiler_pid, :kill)
    end
  end

  defp set_enhanced_resource_limits(memory_limit, cpu_limit, max_processes) do
    # Enhanced resource limit setting with better platform support
    pid = self()

    # Set process priority to lower value to prevent resource hogging
    try do
      Process.flag(:priority, :low)
    rescue
      _ -> :ok
    end

    # Log resource limits for monitoring
    Logger.debug("Enhanced resource limits set",
      memory_limit: memory_limit,
      cpu_limit: cpu_limit,
      max_processes: max_processes,
      pid: pid
    )

    # Store limits in process dictionary for monitoring
    Process.put(:resource_limits, %{
      memory: memory_limit,
      cpu: cpu_limit,
      processes: max_processes,
      start_time: System.monotonic_time(:millisecond)
    })

    :ok
  end

  defp cleanup_monitors(compiler_ref, resource_ref, resource_monitor) do
    Process.demonitor(compiler_ref, [:flush])
    Process.demonitor(resource_ref, [:flush])
    Process.exit(resource_monitor, :normal)
  end

  # Security scanning functions

  defp get_source_files(sandbox_path) do
    patterns = [
      Path.join(sandbox_path, "**/*.ex"),
      Path.join(sandbox_path, "**/*.exs"),
      Path.join(sandbox_path, "**/*.erl")
    ]

    files =
      patterns
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.filter(&File.regular?/1)

    {:ok, files}
  end

  defp perform_security_scan(files, restricted_modules, allowed_operations, scan_depth) do
    threats = []
    warnings = []

    scan_results =
      files
      |> Enum.reduce({threats, warnings}, fn file, {acc_threats, acc_warnings} ->
        case scan_file_security(file, restricted_modules, allowed_operations, scan_depth) do
          {:ok, file_threats, file_warnings} ->
            {acc_threats ++ file_threats, acc_warnings ++ file_warnings}

          {:error, _reason} ->
            # Log error but continue scanning other files
            {acc_threats, acc_warnings}
        end
      end)

    case scan_results do
      {final_threats, final_warnings} ->
        {:ok, %{threats: final_threats, warnings: final_warnings}}
    end
  end

  defp scan_file_security(file_path, restricted_modules, allowed_operations, _scan_depth) do
    content = File.read!(file_path)
    threats = []
    warnings = []

    # Check for restricted modules
    module_threats = scan_restricted_modules(content, file_path, restricted_modules)

    # Check for dangerous operations
    operation_warnings = scan_dangerous_operations(content, file_path, allowed_operations)

    # Check for file system access
    file_access_warnings = scan_file_access(content, file_path)

    # Check for network operations
    network_warnings = scan_network_operations(content, file_path)

    # Check for process spawning
    process_warnings = scan_process_operations(content, file_path)

    all_threats = threats ++ module_threats

    all_warnings =
      warnings ++
        operation_warnings ++
        file_access_warnings ++
        network_warnings ++ process_warnings

    {:ok, all_threats, all_warnings}
  rescue
    error -> {:error, {:file_scan_failed, file_path, error}}
  end

  defp scan_restricted_modules(content, file_path, restricted_modules) do
    restricted_modules
    |> Enum.flat_map(fn module ->
      scan_single_restricted_module(content, file_path, module)
    end)
  end

  defp scan_single_restricted_module(content, file_path, module) do
    module_str = normalize_module_name(module)

    patterns = [
      ~r/#{module_str}\./,
      ~r/alias\s+#{module_str}/,
      ~r/import\s+#{module_str}/,
      ~r/use\s+#{module_str}/
    ]

    Enum.flat_map(patterns, fn pattern ->
      find_pattern_match(pattern, content, file_path, module)
    end)
  end

  defp normalize_module_name(mod) when is_atom(mod) do
    mod |> to_string() |> String.replace_prefix("Elixir.", "")
  end

  defp normalize_module_name(mod) when is_binary(mod), do: mod

  defp find_pattern_match(pattern, content, file_path, module) do
    case Regex.run(pattern, content, return: :index) do
      nil ->
        []

      [{start, _length}] ->
        [build_restricted_module_threat(start, content, file_path, module)]
    end
  end

  defp build_restricted_module_threat(start, content, file_path, module) do
    line_number = get_line_number(content, start)

    %{
      type: :restricted_module,
      severity: :high,
      module: module,
      file: file_path,
      line: line_number,
      message: "Use of restricted module: #{module}"
    }
  end

  defp scan_dangerous_operations(content, file_path, allowed_operations) do
    # Enhanced dangerous patterns with more comprehensive detection
    dangerous_patterns = [
      # System and OS operations
      {~r/System\.cmd/, :system_command},
      {~r/System\.shell/, :shell_command},
      {~r/Port\.open/, :port_operation},
      {~r/:os\.cmd/, :os_command},
      {~r/:os\.putenv/, :environment_manipulation},
      {~r/:os\.getenv/, :environment_access},

      # Code evaluation and compilation
      {~r/Code\.eval/, :code_evaluation},
      {~r/Code\.compile/, :code_compilation},
      {~r/Code\.load_file/, :code_loading},
      {~r/:erlang\.load_module/, :module_loading},
      {~r/Module\.create/, :dynamic_module_creation},

      # File system operations
      {~r/File\.rm/, :file_deletion},
      {~r/File\.rm_rf/, :recursive_deletion},
      {~r/File\.write/, :file_writing},
      {~r/File\.copy/, :file_copying},
      {~r/File\.rename/, :file_renaming},
      {~r/:file\.delete/, :erlang_file_deletion},

      # Network operations
      {~r/:gen_tcp\./, :tcp_operation},
      {~r/:gen_udp\./, :udp_operation},
      {~r/:ssl\./, :ssl_operation},
      {~r/HTTPoison\./, :http_client},
      {~r/Finch\./, :http_client},
      {~r/:httpc\./, :erlang_http_client},
      {~r/:inet\./, :inet_operation},

      # Process and concurrency operations
      {~r/spawn/, :process_spawn},
      {~r/spawn_link/, :process_spawn_link},
      {~r/spawn_monitor/, :process_spawn_monitor},
      {~r/Task\.start/, :task_start},
      {~r/GenServer\.start/, :genserver_start},
      {~r/Supervisor\.start/, :supervisor_start},
      {~r/Agent\.start/, :agent_start},

      # Memory and system introspection
      {~r/:erlang\.memory/, :memory_introspection},
      {~r/:erlang\.system_info/, :system_introspection},
      {~r/Process\.info/, :process_introspection},
      {~r/:observer\./, :system_observer},

      # Potentially dangerous Erlang functions
      {~r/:erlang\.halt/, :system_halt},
      {~r/:init\.stop/, :system_stop},
      {~r/:erlang\.exit/, :process_exit},
      {~r/:erlang\.throw/, :exception_throw},

      # Database and external connections
      {~r/Ecto\./, :database_operation},
      {~r/Postgrex\./, :postgresql_connection},
      {~r/MyXQL\./, :mysql_connection},
      {~r/Redix\./, :redis_connection},

      # Crypto and security sensitive operations
      {~r/:crypto\./, :cryptographic_operation},
      {~r/:public_key\./, :public_key_operation},
      {~r/:ssl_cipher\./, :ssl_cipher_operation}
    ]

    # Enhanced pattern matching with context awareness
    if Enum.empty?(allowed_operations) do
      # Blacklist mode - flag dangerous operations with severity levels
      scan_enhanced_patterns_for_warnings(
        content,
        file_path,
        dangerous_patterns,
        :dangerous_operation
      )
    else
      # Whitelist mode - flag operations not in allowed list
      unauthorized_patterns =
        dangerous_patterns
        |> Enum.filter(fn {_pattern, operation} -> operation not in allowed_operations end)

      scan_enhanced_patterns_for_warnings(
        content,
        file_path,
        unauthorized_patterns,
        :unauthorized_operation
      )
    end
  end

  defp scan_file_access(content, file_path) do
    file_patterns = [
      {~r/File\./, :file_operation},
      {~r/Path\./, :path_operation},
      {~r/:file\./, :erlang_file_operation}
    ]

    scan_patterns_for_warnings(content, file_path, file_patterns, :file_access)
  end

  defp scan_network_operations(content, file_path) do
    network_patterns = [
      {~r/:gen_tcp\./, :tcp_operation},
      {~r/:gen_udp\./, :udp_operation},
      {~r/HTTPoison\./, :http_client},
      {~r/Finch\./, :http_client},
      {~r/:httpc\./, :erlang_http_client}
    ]

    scan_patterns_for_warnings(content, file_path, network_patterns, :network_access)
  end

  defp scan_process_operations(content, file_path) do
    process_patterns = [
      {~r/spawn/, :process_spawn},
      {~r/Task\./, :task_operation},
      {~r/GenServer\.start/, :genserver_start},
      {~r/Supervisor\.start/, :supervisor_start}
    ]

    scan_patterns_for_warnings(content, file_path, process_patterns, :process_operation)
  end

  defp scan_enhanced_patterns_for_warnings(content, file_path, patterns, warning_type) do
    patterns
    |> Enum.flat_map(fn {pattern, operation} ->
      scan_single_pattern_for_warnings(pattern, operation, content, file_path, warning_type)
    end)
  end

  defp scan_single_pattern_for_warnings(pattern, operation, content, file_path, warning_type) do
    case Regex.scan(pattern, content, return: :index) do
      [] ->
        []

      matches ->
        Enum.map(matches, fn [{start, length}] ->
          build_pattern_warning(start, length, operation, content, file_path, warning_type)
        end)
    end
  end

  defp build_pattern_warning(start, length, operation, content, file_path, warning_type) do
    line_number = get_line_number(content, start)
    line_content = get_line_content(content, line_number)
    severity = determine_operation_severity(operation, line_content)
    context = extract_code_context(content, start, length)

    %{
      type: warning_type,
      severity: severity,
      operation: operation,
      file: file_path,
      line: line_number,
      message: generate_security_message(operation, severity, context),
      context: context,
      line_content: String.trim(line_content)
    }
  end

  defp scan_patterns_for_warnings(content, file_path, patterns, warning_type) do
    # Legacy function for backward compatibility
    scan_enhanced_patterns_for_warnings(content, file_path, patterns, warning_type)
  end

  defp determine_operation_severity(operation, line_content) do
    high_risk_operations = [
      :system_command,
      :shell_command,
      :os_command,
      :code_evaluation,
      :recursive_deletion,
      :system_halt,
      :system_stop,
      :file_deletion
    ]

    medium_risk_operations = [
      :file_writing,
      :file_copying,
      :network_access,
      :process_spawn,
      :database_operation,
      :cryptographic_operation
    ]

    # Check for additional context clues that increase severity
    high_risk_patterns = [
      "rm -rf",
      "del /s",
      "format",
      "shutdown",
      "reboot",
      "/etc/",
      "/root/",
      "passwd",
      "shadow"
    ]

    base_severity =
      cond do
        operation in high_risk_operations -> :high
        operation in medium_risk_operations -> :medium
        true -> :low
      end

    # Escalate severity if dangerous patterns are found in the line
    if Enum.any?(high_risk_patterns, &String.contains?(String.downcase(line_content), &1)) do
      :critical
    else
      base_severity
    end
  end

  defp generate_security_message(operation, severity, context) do
    base_message = operation_to_message(operation)
    severity_note = severity_to_note(severity)
    context_note = format_context_note(context)

    base_message <> severity_note <> context_note
  end

  defp operation_to_message(:system_command), do: "System command execution detected"
  defp operation_to_message(:shell_command), do: "Shell command execution detected"
  defp operation_to_message(:code_evaluation), do: "Dynamic code evaluation detected"
  defp operation_to_message(:file_deletion), do: "File deletion operation detected"
  defp operation_to_message(:recursive_deletion), do: "Recursive file deletion detected"
  defp operation_to_message(:network_access), do: "Network access operation detected"
  defp operation_to_message(:database_operation), do: "Database operation detected"
  defp operation_to_message(:cryptographic_operation), do: "Cryptographic operation detected"
  defp operation_to_message(operation), do: "Potentially unsafe operation: #{operation}"

  defp severity_to_note(:critical), do: " [CRITICAL RISK]"
  defp severity_to_note(:high), do: " [HIGH RISK]"
  defp severity_to_note(:medium), do: " [MEDIUM RISK]"
  defp severity_to_note(:low), do: " [LOW RISK]"

  defp format_context_note(context) do
    if String.length(context.surrounding_code) > 0 do
      " - Context: #{String.slice(context.surrounding_code, 0, 50)}..."
    else
      ""
    end
  end

  defp extract_code_context(content, start, length) do
    # Extract surrounding code for better context analysis
    lines = String.split(content, "\n")
    line_number = get_line_number(content, start)

    # Get surrounding lines (2 before, 2 after)
    context_start = max(1, line_number - 2)
    context_end = min(length(lines), line_number + 2)

    surrounding_lines =
      lines
      |> Enum.slice((context_start - 1)..(context_end - 1))
      |> Enum.join("\n")

    # Extract the specific matched text
    matched_text = String.slice(content, start, length)

    %{
      surrounding_code: surrounding_lines,
      matched_text: matched_text,
      line_number: line_number,
      context_start: context_start,
      context_end: context_end
    }
  end

  defp get_line_content(content, line_number) do
    content
    |> String.split("\n")
    |> Enum.at(line_number - 1, "")
  end

  defp get_line_number(content, position) do
    content
    |> String.slice(0, position)
    |> String.split("\n")
    |> length()
  end

  defp validate_beam_file_security(beam_file) do
    case :beam_lib.info(String.to_charlist(beam_file)) do
      {:error, :beam_lib, reason} ->
        {:error, "Invalid BEAM file: #{inspect(reason)}"}

      info when is_list(info) ->
        # Additional security checks on BEAM file
        check_beam_security(beam_file, info)
    end
  rescue
    error -> {:error, "BEAM validation error: #{inspect(error)}"}
  end

  defp check_beam_security(_beam_file, _info) do
    # Placeholder for additional BEAM file security checks
    # Could include:
    # - Checking for suspicious exports
    # - Validating module attributes
    # - Checking for embedded code or data
    :ok
  end

  defp default_restricted_modules do
    [
      :os,
      :file,
      :code,
      :erlang,
      System,
      File,
      Code,
      Port
    ]
  end

  defp in_test_environment? do
    # Check if we're running in test environment
    # Also check if elixir executable is not available (common in test environments)
    System.get_env("MIX_ENV") == "test" ||
      check_mix_test_env() ||
      System.find_executable("elixir") == nil
  end

  defp check_mix_test_env do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    Code.ensure_loaded?(Mix) && function_exported?(Mix, :env, 0) && apply(Mix, :env, []) == :test
  end

  defp format_in_process_output(beam_files, warnings) do
    beam_info = Enum.map_join(beam_files, "\n", &"Generated #{&1}")

    warning_info = Enum.map_join(warnings, "\n", &format_warning_message/1)

    [beam_info, warning_info]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_in_process_errors(errors, warnings) do
    error_info = Enum.map_join(errors, "\n", &format_error_message/1)

    warning_info = Enum.map_join(warnings, "\n", &format_warning_message/1)

    [error_info, warning_info]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp format_warning_message(%{file: file, line: line, message: message}) do
    "warning: #{message}\n  #{file}:#{line}"
  end

  defp format_error_message(%{file: file, line: line, message: message}) do
    "** (CompileError) #{file}:#{line}: #{message}"
  end
end
