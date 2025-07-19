defmodule Sandbox.Models.CompilationResult do
  @moduledoc """
  Data model for compilation results and metadata.

  This struct represents the result of a compilation operation,
  including success/failure status, output files, warnings, and errors.
  """

  @type warning :: %{
          file: String.t(),
          line: non_neg_integer(),
          message: String.t()
        }

  @type error :: %{
          file: String.t(),
          line: non_neg_integer(),
          message: String.t(),
          type: :syntax | :compile | :dependency
        }

  @type t :: %__MODULE__{
          status: :success | :failure,
          output: String.t(),
          beam_files: [String.t()],
          app_file: String.t() | nil,
          warnings: [warning()],
          errors: [error()],
          compilation_time: non_neg_integer(),
          temp_dir: String.t(),
          incremental: boolean()
        }

  defstruct [
    :status,
    :output,
    :beam_files,
    :app_file,
    :warnings,
    :errors,
    :compilation_time,
    :temp_dir,
    :incremental
  ]

  @doc """
  Creates a successful compilation result.
  """
  def success(opts \\ []) do
    %__MODULE__{
      status: :success,
      output: Keyword.get(opts, :output, ""),
      beam_files: Keyword.get(opts, :beam_files, []),
      app_file: Keyword.get(opts, :app_file),
      warnings: Keyword.get(opts, :warnings, []),
      errors: [],
      compilation_time: Keyword.get(opts, :compilation_time, 0),
      temp_dir: Keyword.get(opts, :temp_dir, ""),
      incremental: Keyword.get(opts, :incremental, false)
    }
  end

  @doc """
  Creates a failed compilation result.
  """
  def failure(errors, opts \\ []) do
    %__MODULE__{
      status: :failure,
      output: Keyword.get(opts, :output, ""),
      beam_files: [],
      app_file: nil,
      warnings: Keyword.get(opts, :warnings, []),
      errors: errors,
      compilation_time: Keyword.get(opts, :compilation_time, 0),
      temp_dir: Keyword.get(opts, :temp_dir, ""),
      incremental: Keyword.get(opts, :incremental, false)
    }
  end

  @doc """
  Creates a warning specification.
  """
  def warning(file, line, message) do
    %{file: file, line: line, message: message}
  end

  @doc """
  Creates an error specification.
  """
  def error(file, line, message, type \\ :compile) do
    %{file: file, line: line, message: message, type: type}
  end

  @doc """
  Checks if the compilation was successful.
  """
  def success?(%__MODULE__{status: :success}), do: true
  def success?(%__MODULE__{}), do: false

  @doc """
  Gets the total number of issues (warnings + errors).
  """
  def issue_count(%__MODULE__{warnings: warnings, errors: errors}) do
    length(warnings) + length(errors)
  end

  @doc """
  Converts compilation result to a summary map.
  """
  def to_summary(%__MODULE__{} = result) do
    %{
      status: result.status,
      beam_count: length(result.beam_files),
      warning_count: length(result.warnings),
      error_count: length(result.errors),
      compilation_time: result.compilation_time,
      incremental: result.incremental
    }
  end
end
