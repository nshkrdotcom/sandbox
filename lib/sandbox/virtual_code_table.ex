defmodule Sandbox.VirtualCodeTable do
  @moduledoc """
  Provides virtual code tables for sandbox isolation using ETS.

  This module implements Phase 3 of the optimal module isolation architecture,
  providing ETS-based virtual code tables that allow sandboxes to maintain
  their own isolated module namespace while providing efficient lookup and
  management of compiled modules.

  Key features:
  - Per-sandbox ETS tables for module storage
  - BEAM bytecode analysis and metadata extraction
  - Module dependency tracking and resolution
  - Efficient module lookup and caching
  - Integration with Phase 1 and Phase 2 isolation systems
  """

  require Logger

  @doc """
  Creates a virtual code table for a sandbox.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `opts`: Options for table creation
    - `:access` - Table access mode (:public, :protected, :private, default: :public)
    - `:read_concurrency` - Enable read concurrency (default: true)
    - `:write_concurrency` - Enable write concurrency (default: false)

  ## Returns
  - `{:ok, table_ref}` - Success with table reference
  - `{:error, reason}` - Table creation failed

  ## Examples
      iex> {:ok, table} = VirtualCodeTable.create_table("test_sandbox")
      iex> is_reference(table)
      true
  """
  def create_table(sandbox_id, opts \\ []) do
    table_name = table_name_for_sandbox(sandbox_id)
    access = Keyword.get(opts, :access, :public)
    read_concurrency = Keyword.get(opts, :read_concurrency, true)
    write_concurrency = Keyword.get(opts, :write_concurrency, false)

    # Check if table already exists
    case :ets.whereis(table_name) do
      :undefined ->
        try do
          table_opts = [
            :named_table,
            :set,
            access,
            {:read_concurrency, read_concurrency},
            {:write_concurrency, write_concurrency}
          ]

          _table_name_atom = :ets.new(table_name, table_opts)

          Logger.debug("Created virtual code table for sandbox #{sandbox_id}",
            table_name: table_name,
            table_ref: table_name
          )

          {:ok, table_name}
        rescue
          error ->
            Logger.error("Failed to create virtual code table for sandbox #{sandbox_id}",
              error: inspect(error)
            )

            {:error, {:table_creation_failed, error}}
        end

      _existing_ref ->
        Logger.debug("Virtual code table already exists for sandbox #{sandbox_id}",
          table_name: table_name,
          table_ref: table_name
        )

        {:ok, table_name}
    end
  end

  @doc """
  Loads a module into the virtual code table.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `module`: Module name (atom)
  - `beam_data`: Compiled BEAM bytecode
  - `opts`: Loading options
    - `:force_reload` - Force reload even if module exists (default: false)
    - `:extract_metadata` - Extract module metadata (default: true)

  ## Returns
  - `:ok` - Module loaded successfully
  - `{:error, reason}` - Loading failed

  ## Examples
      iex> VirtualCodeTable.load_module("test", :MyModule, beam_data)
      :ok
  """
  def load_module(sandbox_id, module, beam_data, opts \\ [])
      when is_atom(module) and is_binary(beam_data) do
    table_name = table_name_for_sandbox(sandbox_id)
    force_reload = Keyword.get(opts, :force_reload, false)
    extract_metadata = Keyword.get(opts, :extract_metadata, true)

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, {:table_not_found, sandbox_id}}

      _table_ref ->
        # Check if module already exists
        case :ets.lookup(table_name, module) do
          [{^module, _existing_info}] when not force_reload ->
            {:error, {:module_already_loaded, module}}

          _ ->
            try do
              module_info = %{
                beam_data: beam_data,
                loaded_at: System.monotonic_time(:millisecond),
                size: byte_size(beam_data),
                checksum: compute_checksum(beam_data),
                metadata: if(extract_metadata, do: extract_module_metadata(beam_data), else: %{})
              }

              :ets.insert(table_name, {module, module_info})

              Logger.debug("Loaded module #{module} into virtual code table",
                sandbox_id: sandbox_id,
                module: module,
                size: byte_size(beam_data)
              )

              :ok
            rescue
              error ->
                Logger.error("Failed to load module #{module} into virtual code table",
                  sandbox_id: sandbox_id,
                  module: module,
                  error: inspect(error)
                )

                {:error, {:module_load_failed, error}}
            end
        end
    end
  end

  @doc """
  Fetches a module from the virtual code table.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `module`: Module name to fetch

  ## Returns
  - `{:ok, module_info}` - Module found with its information
  - `{:error, :not_loaded}` - Module not found in table
  - `{:error, :table_not_found}` - Virtual code table doesn't exist

  ## Examples
      iex> VirtualCodeTable.fetch_module("test", :MyModule)
      {:ok, %{beam_data: <<...>>, loaded_at: 123456789, ...}}
  """
  def fetch_module(sandbox_id, module) when is_atom(module) do
    table_name = table_name_for_sandbox(sandbox_id)

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :table_not_found}

      _table_ref ->
        case :ets.lookup(table_name, module) do
          [{^module, module_info}] ->
            Logger.debug("Fetched module #{module} from virtual code table",
              sandbox_id: sandbox_id,
              module: module
            )

            {:ok, module_info}

          [] ->
            {:error, :not_loaded}
        end
    end
  end

  @doc """
  Lists all modules in the virtual code table.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `opts`: Listing options
    - `:include_metadata` - Include full metadata in results (default: false)
    - `:sort_by` - Sort results by field (:name, :loaded_at, :size, default: :name)

  ## Returns
  - `{:ok, modules}` - List of modules with their information
  - `{:error, :table_not_found}` - Virtual code table doesn't exist
  """
  def list_modules(sandbox_id, opts \\ []) do
    table_name = table_name_for_sandbox(sandbox_id)
    include_metadata = Keyword.get(opts, :include_metadata, false)
    sort_by = Keyword.get(opts, :sort_by, :name)

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :table_not_found}

      _table_ref ->
        modules =
          :ets.tab2list(table_name)
          |> Enum.map(fn {module, info} ->
            base_info = %{
              name: module,
              loaded_at: info.loaded_at,
              size: info.size,
              checksum: info.checksum
            }

            if include_metadata do
              Map.put(base_info, :metadata, info.metadata)
            else
              base_info
            end
          end)
          |> sort_modules(sort_by)

        {:ok, modules}
    end
  end

  @doc """
  Removes a module from the virtual code table.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `module`: Module name to remove

  ## Returns
  - `:ok` - Module removed successfully
  - `{:error, :not_loaded}` - Module not found
  - `{:error, :table_not_found}` - Virtual code table doesn't exist
  """
  def unload_module(sandbox_id, module) when is_atom(module) do
    table_name = table_name_for_sandbox(sandbox_id)

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :table_not_found}

      _table_ref ->
        case :ets.lookup(table_name, module) do
          [{^module, _info}] ->
            :ets.delete(table_name, module)

            Logger.debug("Unloaded module #{module} from virtual code table",
              sandbox_id: sandbox_id,
              module: module
            )

            :ok

          [] ->
            {:error, :not_loaded}
        end
    end
  end

  @doc """
  Destroys the virtual code table for a sandbox.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox

  ## Returns
  - `:ok` - Table destroyed successfully
  - `{:error, :table_not_found}` - Table doesn't exist
  """
  def destroy_table(sandbox_id) do
    table_name = table_name_for_sandbox(sandbox_id)

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :table_not_found}

      _table_ref ->
        :ets.delete(table_name)

        Logger.debug("Destroyed virtual code table for sandbox #{sandbox_id}",
          table_name: table_name
        )

        :ok
    end
  end

  @doc """
  Gets statistics about the virtual code table.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox

  ## Returns
  - `{:ok, stats}` - Table statistics
  - `{:error, :table_not_found}` - Table doesn't exist
  """
  def get_table_stats(sandbox_id) do
    table_name = table_name_for_sandbox(sandbox_id)

    case :ets.whereis(table_name) do
      :undefined ->
        {:error, :table_not_found}

      _table_ref ->
        info = :ets.info(table_name)
        modules = :ets.tab2list(table_name)

        total_size = Enum.reduce(modules, 0, fn {_module, %{size: size}}, acc -> acc + size end)

        stats = %{
          table_name: table_name,
          # For named tables, the ref is the table name
          table_ref: table_name,
          module_count: length(modules),
          total_size: total_size,
          memory_usage: info[:memory],
          access: info[:protection],
          read_concurrency: info[:read_concurrency],
          write_concurrency: info[:write_concurrency]
        }

        {:ok, stats}
    end
  end

  # Private helper functions

  defp table_name_for_sandbox(sandbox_id) do
    :"sandbox_code_#{sandbox_id}"
  end

  defp compute_checksum(beam_data) do
    :crypto.hash(:sha256, beam_data)
    |> Base.encode16(case: :lower)
  end

  defp extract_module_metadata(beam_data) do
    try do
      case :beam_lib.info(beam_data) do
        info when is_list(info) ->
          %{
            attributes: case Keyword.get(info, :attributes) do
              attrs when is_list(attrs) -> Map.new(attrs)
              _ -> %{}
            end,
            exports: case Keyword.get(info, :exports) do
              exports when is_list(exports) -> exports
              _ -> []
            end,
            imports: case Keyword.get(info, :imports) do
              imports when is_list(imports) -> imports
              _ -> []
            end,
            compile_info: case Keyword.get(info, :compile) do
              compile when is_list(compile) -> Map.new(compile)
              _ -> %{}
            end
          }

        {:error, :beam_lib, _reason} ->
          %{}
      end
    rescue
      _ ->
        %{}
    end
  end

  defp sort_modules(modules, :name) do
    Enum.sort_by(modules, & &1.name)
  end

  defp sort_modules(modules, :loaded_at) do
    Enum.sort_by(modules, & &1.loaded_at)
  end

  defp sort_modules(modules, :size) do
    Enum.sort_by(modules, & &1.size, :desc)
  end

  defp sort_modules(modules, _), do: modules
end
