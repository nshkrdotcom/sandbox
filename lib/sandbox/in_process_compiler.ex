defmodule Sandbox.InProcessCompiler do
  @moduledoc """
  Alternative compilation strategy that compiles Elixir code in-process
  without spawning external executables.
  """

  require Logger

  @doc """
  Compiles Elixir source files in-process using the Elixir compiler APIs.
  """
  def compile_in_process(source_path, output_path, opts \\ []) do
    if File.exists?(source_path) do
      with_global_compile_lock(fn ->
        do_compile_in_process(source_path, output_path, opts)
      end)
    else
      Logger.error("Source path not found: #{source_path}")
      {:error, {:source_path_not_found, source_path}}
    end
  end

  defp with_global_compile_lock(fun) do
    lock_key = {:sandbox_in_process_compile, node()}

    case :global.trans(lock_key, fun, [node()], 30_000) do
      :aborted ->
        {:error, :compile_lock_timeout}

      result ->
        result
    end
  end

  defp do_compile_in_process(source_path, output_path, opts) do
    original_cwd = get_original_cwd()
    original_compiler_options = Code.compiler_options()
    ignore_consolidated = Keyword.get(opts, :ignore_already_consolidated, false)

    try do
      File.mkdir_p!(output_path)

      if ignore_consolidated do
        Code.compiler_options(ignore_already_consolidated: true)
      end

      source_files = pick_source_files(source_path, opts)
      Logger.debug("In-process compiler found #{length(source_files)} files in #{source_path}")

      source_files_specified = Keyword.has_key?(opts, :source_files)

      result =
        compile_source_files(
          source_files,
          source_path,
          output_path,
          Keyword.put(opts, :source_files_specified, source_files_specified)
        )

      restore_cwd(original_cwd)
      result
    rescue
      error ->
        restore_cwd(original_cwd)
        Logger.error("In-process compilation failed: #{inspect(error)}")
        Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
        {:error, {:compilation_failed, error}}
    after
      Code.compiler_options(original_compiler_options)
    end
  end

  defp get_original_cwd do
    case File.cwd() do
      {:ok, cwd} -> cwd
      {:error, _} -> nil
    end
  end

  defp restore_cwd(nil), do: :ok

  defp restore_cwd(original_cwd) do
    if File.exists?(original_cwd), do: File.cd!(original_cwd)
  end

  defp compile_source_files([], source_path, output_path, opts) do
    if Keyword.get(opts, :source_files_specified, false) do
      {:ok, %{beam_files: [], warnings: [], modules: []}}
    else
      root_files = Path.wildcard(Path.join(source_path, "*.ex"))

      if Enum.empty?(root_files) do
        {:ok, %{beam_files: [], warnings: [], modules: []}}
      else
        compile_result = compile_files(root_files, output_path, opts)
        handle_compile_result(compile_result, output_path)
      end
    end
  end

  defp compile_source_files(source_files, _source_path, output_path, opts) do
    compile_result = compile_files(source_files, output_path, opts)
    handle_compile_result(compile_result, output_path)
  end

  defp handle_compile_result(compile_result, output_path) do
    case compile_result do
      {:ok, modules, warnings} ->
        beam_files =
          Enum.map(modules, fn module ->
            Path.join(output_path, "#{module}.beam")
          end)

        {:ok,
         %{
           beam_files: beam_files,
           warnings: format_warnings(warnings),
           modules: modules
         }}

      {:error, errors, warnings} ->
        {:error,
         %{
           errors: format_errors(errors),
           warnings: format_warnings(warnings)
         }}
    end
  end

  @doc """
  Compiles a single Elixir module from string source.
  """
  def compile_string(source_code, module_name, output_path \\ nil) do
    # Create a temporary file or use in-memory compilation
    if output_path do
      File.mkdir_p!(output_path)
    end

    # Use Code.compile_string/2
    case Code.compile_string(source_code, module_name) do
      [] ->
        {:error, :no_bytecode_generated}

      compiled ->
        modules =
          Enum.map(compiled, fn {module, bytecode} ->
            maybe_write_beam_file(output_path, module, bytecode)
            module
          end)

        {:ok, modules}
    end
  rescue
    error ->
      {:error, {:compilation_error, error}}
  end

  @doc """
  Loads compiled BEAM files into the current VM.
  """
  def load_beam_files(beam_files) do
    Enum.reduce_while(beam_files, {:ok, []}, fn beam_file, {:ok, loaded} ->
      case load_beam_file(beam_file) do
        {:ok, module} ->
          {:cont, {:ok, [module | loaded]}}

        {:error, reason} ->
          {:halt, {:error, {:load_failed, beam_file, reason}}}
      end
    end)
  end

  # Private functions

  defp maybe_write_beam_file(nil, _module, _bytecode), do: :ok

  defp maybe_write_beam_file(output_path, module, bytecode) do
    beam_file = Path.join(output_path, "#{module}.beam")
    File.write!(beam_file, bytecode)
  end

  defp find_source_files(source_path) do
    Path.wildcard(Path.join([source_path, "**", "*.ex"]))
  end

  defp pick_source_files(source_path, opts) do
    case Keyword.fetch(opts, :source_files) do
      :error -> find_source_files(source_path)
      {:ok, files} -> normalize_source_files(source_path, files)
    end
  end

  defp normalize_source_files(source_path, files) do
    files
    |> Enum.map(fn file ->
      file = to_string(file)

      case Path.type(file) do
        :absolute -> file
        _ -> Path.join(source_path, file)
      end
    end)
  end

  defp compile_files(source_files, output_path, opts) do
    # Set compiler options
    compiler_opts = [
      dest: output_path,
      debug_info: Keyword.get(opts, :debug_info, true),
      return_diagnostics: true
    ]

    # Use absolute paths to avoid cwd dependency
    absolute_source_files = Enum.map(source_files, &Path.expand/1)
    absolute_output_path = Path.expand(output_path)

    parallel? = Keyword.get(opts, :parallel, false) and length(absolute_source_files) > 1

    if parallel? do
      Kernel.ParallelCompiler.compile_to_path(
        absolute_source_files,
        absolute_output_path,
        compiler_opts
      )
    else
      compile_files_serial(absolute_source_files, absolute_output_path)
    end
  end

  defp compile_files_serial(source_files, output_path) do
    modules =
      Enum.flat_map(source_files, fn file ->
        compiled = Code.compile_file(file)

        Enum.map(compiled, fn {module, bytecode} ->
          maybe_write_beam_file(output_path, module, bytecode)
          module
        end)
      end)

    {:ok, modules, []}
  rescue
    error ->
      {:error, [compile_exception_to_diagnostic(error)], []}
  end

  defp compile_exception_to_diagnostic(error) do
    file = Map.get(error, :file, "unknown") |> to_string()
    line = Map.get(error, :line)
    %{file: file, line: line, message: Exception.message(error), severity: :error}
  end

  defp load_beam_file(beam_file) do
    case File.read(beam_file) do
      {:ok, bytecode} ->
        module_name = Path.basename(beam_file, ".beam") |> String.to_atom()

        case :code.load_binary(module_name, String.to_charlist(beam_file), bytecode) do
          {:module, module} ->
            {:ok, module}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:file_read_error, reason}}
    end
  end

  defp format_warnings(warnings) do
    Enum.map(warnings, &format_diagnostic(&1, :warning, false))
  end

  defp format_errors(errors) do
    Enum.map(errors, &format_diagnostic(&1, :error, true))
  end

  defp format_diagnostic({file, line, message}, severity, include_severity?) do
    base = %{
      file: to_string(file),
      line: line,
      message: format_message(message)
    }

    if include_severity? do
      Map.put(base, :severity, severity)
    else
      base
    end
  end

  defp format_diagnostic(%{file: _file} = diagnostic, severity, include_severity?) do
    file = diagnostic_file(diagnostic)
    line = diagnostic_line(diagnostic)
    message = Map.get(diagnostic, :message, diagnostic)

    base = %{
      file: file,
      line: line,
      message: format_message(message)
    }

    if include_severity? do
      Map.put(base, :severity, Map.get(diagnostic, :severity, severity))
    else
      base
    end
  end

  defp format_diagnostic(other, severity, include_severity?) do
    base = %{
      file: "unknown",
      line: nil,
      message: format_message(other)
    }

    if include_severity? do
      Map.put(base, :severity, severity)
    else
      base
    end
  end

  defp diagnostic_file(diagnostic) do
    case Map.get(diagnostic, :file) do
      nil -> "unknown"
      file -> to_string(file)
    end
  end

  defp diagnostic_line(diagnostic) do
    case Map.get(diagnostic, :position) do
      {line, _column} -> line
      line when is_integer(line) -> line
      nil -> Map.get(diagnostic, :line)
      _ -> nil
    end
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message), do: inspect(message)
end
