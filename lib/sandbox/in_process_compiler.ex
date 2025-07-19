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
    # Ensure source path exists
    if not File.exists?(source_path) do
      Logger.error("Source path not found: #{source_path}")
      {:error, {:source_path_not_found, source_path}}
    else
      # Preserve current working directory
      original_cwd =
        case File.cwd() do
          {:ok, cwd} -> cwd
          {:error, _} -> nil
        end

      try do
        # Ensure output directory exists
        File.mkdir_p!(output_path)

        # Find all .ex files
        source_files = find_source_files(source_path)

        Logger.debug("In-process compiler found #{length(source_files)} files in #{source_path}")

        result =
          if Enum.empty?(source_files) do
            # If no .ex files in subdirectories, check for modules in root
            root_files = Path.wildcard(Path.join(source_path, "*.ex"))

            if Enum.empty?(root_files) do
              {:ok, %{beam_files: [], warnings: [], modules: []}}
            else
              compile_result = compile_files(root_files, output_path, opts)
              handle_compile_result(compile_result, output_path)
            end
          else
            # Compile files using Kernel.ParallelCompiler
            compile_result = compile_files(source_files, output_path, opts)
            handle_compile_result(compile_result, output_path)
          end

        # Restore original working directory if we have one
        if original_cwd && File.exists?(original_cwd) do
          File.cd!(original_cwd)
        end

        result
      rescue
        error ->
          # Try to restore working directory even on error
          if original_cwd && File.exists?(original_cwd) do
            File.cd!(original_cwd)
          end

          Logger.error("In-process compilation failed: #{inspect(error)}")
          Logger.error("Stacktrace: #{inspect(__STACKTRACE__)}")
          {:error, {:compilation_failed, error}}
      end
    end
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
    try do
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
              if output_path do
                beam_file = Path.join(output_path, "#{module}.beam")
                File.write!(beam_file, bytecode)
              end

              module
            end)

          {:ok, modules}
      end
    rescue
      error ->
        {:error, {:compilation_error, error}}
    end
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

  defp find_source_files(source_path) do
    Path.wildcard(Path.join([source_path, "**", "*.ex"]))
  end

  defp compile_files(source_files, output_path, opts) do
    # Set compiler options
    compiler_opts = [
      dest: output_path,
      debug_info: Keyword.get(opts, :debug_info, true)
    ]

    # Use absolute paths to avoid cwd dependency
    absolute_source_files = Enum.map(source_files, &Path.expand/1)
    absolute_output_path = Path.expand(output_path)

    # Use Kernel.ParallelCompiler for actual compilation
    case Kernel.ParallelCompiler.compile_to_path(
           absolute_source_files,
           absolute_output_path,
           compiler_opts
         ) do
      {:ok, modules, warnings} ->
        {:ok, modules, warnings}

      {:error, errors, warnings} ->
        {:error, errors, warnings}
    end
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
    Enum.map(warnings, fn {file, line, message} ->
      %{
        file: to_string(file),
        line: line,
        message: format_message(message)
      }
    end)
  end

  defp format_errors(errors) do
    Enum.map(errors, fn {file, line, message} ->
      %{
        file: to_string(file),
        line: line,
        message: format_message(message),
        severity: :error
      }
    end)
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message), do: inspect(message)
end
