defmodule Sandbox.Models.ModuleVersion do
  @moduledoc """
  Data model for module version tracking and metadata.

  This struct represents a specific version of a module within a sandbox,
  including its bytecode, dependencies, and metadata.
  """

  @type dependency :: %{
          module: atom(),
          type: :compile_time | :runtime | :optional,
          version_constraint: String.t() | nil
        }

  @type t :: %__MODULE__{
          sandbox_id: String.t(),
          module: atom(),
          version: non_neg_integer(),
          beam_data: binary(),
          source_checksum: String.t(),
          beam_checksum: String.t(),
          loaded_at: DateTime.t(),
          dependencies: [dependency()],
          metadata: map()
        }

  defstruct [
    :sandbox_id,
    :module,
    :version,
    :beam_data,
    :source_checksum,
    :beam_checksum,
    :loaded_at,
    :dependencies,
    :metadata
  ]

  @doc """
  Creates a new module version record.
  """
  def new(sandbox_id, module, beam_data, opts \\ []) do
    beam_checksum = :crypto.hash(:sha256, beam_data) |> Base.encode16(case: :lower)

    %__MODULE__{
      sandbox_id: sandbox_id,
      module: module,
      version: Keyword.get(opts, :version, 1),
      beam_data: beam_data,
      source_checksum: Keyword.get(opts, :source_checksum, ""),
      beam_checksum: beam_checksum,
      loaded_at: DateTime.utc_now(),
      dependencies: Keyword.get(opts, :dependencies, []),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Creates a dependency specification.
  """
  def dependency(module, type \\ :runtime, version_constraint \\ nil) do
    %{
      module: module,
      type: type,
      version_constraint: version_constraint
    }
  end

  @doc """
  Converts module version to a map for external consumption.
  """
  def to_info(%__MODULE__{} = version) do
    %{
      sandbox_id: version.sandbox_id,
      module: version.module,
      version: version.version,
      loaded_at: version.loaded_at,
      dependencies: version.dependencies,
      checksum: version.beam_checksum
    }
  end

  @doc """
  Checks if two module versions are identical based on their checksums.
  """
  def identical?(%__MODULE__{} = v1, %__MODULE__{} = v2) do
    v1.beam_checksum == v2.beam_checksum
  end

  @doc """
  Gets the size of the BEAM data in bytes.
  """
  def beam_size(%__MODULE__{beam_data: beam_data}) do
    byte_size(beam_data)
  end
end
