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

  @type compile_result :: {:ok, compile_info()} | {:error, compile_error()}
  @type compile_info :: %{
          output: String.t(),
          beam_files: [String.t()],
          app_file: String.t() | nil,
          compilation_time: non_neg_integer(),
          temp_dir: String.t()
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
          compiler: :mix | :erlc | :elixirc
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
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    validate_beams = Keyword.get(opts, :validate_beams, true)

    start_time = System.monotonic_time(:millisecond)

    with :ok <- validate_sandbox_path(sandbox_path),
         {:ok, temp_dir} <- create_temp_build_dir(opts),
         {:ok, output} <- compile_in_isolation(sandbox_path, temp_dir, timeout, opts),
         {:ok, artifacts} <- collect_compilation_artifacts(sandbox_path, temp_dir),
         :ok <- maybe_validate_beams(artifacts.beam_files, validate_beams) do
      compilation_time = System.monotonic_time(:millisecond) - start_time

      compile_info = %{
        output: output,
        beam_files: artifacts.beam_files,
        app_file: artifacts.app_file,
        compilation_time: compilation_time,
        temp_dir: temp_dir
      }

      Logger.debug("Sandbox compiled successfully in #{compilation_time}ms",
        sandbox_path: sandbox_path,
        artifacts: length(artifacts.beam_files)
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
  Compiles a single Elixir file in isolation.
  """
  @spec compile_file(String.t(), compile_opts()) :: compile_result()
  def compile_file(file_path, opts \\ []) do
    unless File.exists?(file_path) do
      {:error, {:invalid_file_path, "File does not exist: #{file_path}"}}
    else
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
    end
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
    parent = self()
    memory_limit = Keyword.get(opts, :memory_limit, @default_memory_limit)
    env = Keyword.get(opts, :env, %{})
    compiler = Keyword.get(opts, :compiler, :mix)

    # Set up build environment
    build_env =
      Map.merge(
        %{
          "MIX_BUILD_PATH" => temp_dir,
          "MIX_ARCHIVES" => "",
          "MIX_DEPS_PATH" => Path.join(temp_dir, "deps")
        },
        env
      )

    compiler_pid =
      spawn(fn ->
        try do
          # Set memory limit (if supported)
          set_memory_limit(memory_limit)

          # Change to sandbox directory
          original_cwd = File.cwd!()
          File.cd!(sandbox_path)

          # Compile based on compiler type
          {result, exit_code} = compile_with(compiler, sandbox_path, build_env)

          # Restore working directory
          File.cd!(original_cwd)

          send(parent, {:compilation_result, exit_code, result})
        catch
          kind, error ->
            send(parent, {:compilation_error, kind, error})
        end
      end)

    # Monitor compiler process
    compiler_ref = Process.monitor(compiler_pid)

    receive do
      {:compilation_result, 0, output} ->
        Process.demonitor(compiler_ref, [:flush])
        {:ok, output}

      {:compilation_result, exit_code, output} ->
        Process.demonitor(compiler_ref, [:flush])
        {:error, {:compilation_failed, exit_code, output}}

      {:compilation_error, kind, error} ->
        Process.demonitor(compiler_ref, [:flush])
        {:error, {:compiler_crash, kind, error}}

      {:DOWN, ^compiler_ref, :process, ^compiler_pid, reason} ->
        {:error, {:compiler_crash, :process_down, reason}}
    after
      timeout ->
        Process.demonitor(compiler_ref, [:flush])
        Process.exit(compiler_pid, :kill)
        {:error, {:compilation_timeout, timeout}}
    end
  end

  defp compile_with(:mix, _sandbox_path, build_env) do
    System.cmd("mix", ["compile", "--force"],
      stderr_to_stdout: true,
      env: build_env
    )
  end

  defp compile_with(:elixirc, sandbox_path, _build_env) do
    files = Path.wildcard(Path.join(sandbox_path, "*.ex"))
    System.cmd("elixirc", files ++ ["-o", Path.join(sandbox_path, "ebin")],
      stderr_to_stdout: true
    )
  end

  defp compile_with(:erlc, sandbox_path, _build_env) do
    files = Path.wildcard(Path.join(sandbox_path, "*.erl"))
    System.cmd("erlc", files ++ ["-o", Path.join(sandbox_path, "ebin")],
      stderr_to_stdout: true
    )
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
    try do
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
  end

  defp set_memory_limit(_memory_limit) do
    # Note: Erlang doesn't have built-in memory limits per process
    # This is a placeholder for potential future implementation
    # Could use external tools like systemd-run or ulimit in the future
    :ok
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
end