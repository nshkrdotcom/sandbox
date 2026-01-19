defmodule Sandbox.ModuleTransformer do
  @moduledoc """
  Module transformation system that creates unique module names per sandbox.

  This module provides functionality to:
  1. Transform module names to include sandbox-specific prefixes
  2. Update code references to use transformed names
  3. Maintain mapping between original and transformed names
  4. Handle module dependency resolution
  """

  require Logger

  alias Sandbox.Config

  @doc """
  Transforms Elixir source code to use sandbox-specific module names.

  ## Parameters
  - `source_code`: The original Elixir source code as a string
  - `sandbox_id`: Unique identifier for the sandbox
  - `opts`: Options for transformation
    - `:preserve_stdlib` - Don't transform standard library modules (default: true)
    - `:namespace_prefix` - Custom prefix for transformed modules (default: "Sandbox_<sandbox_id>")

  ## Returns
  - `{:ok, transformed_code, module_mapping}` - Success with transformed code and mapping
  - `{:error, reason}` - Transformation failed

  ## Examples
      iex> source = "defmodule MyModule do\\n  def hello, do: :world\\nend"
      iex> {:ok, transformed, mapping} = ModuleTransformer.transform_source(source, "test123")
      iex> String.contains?(transformed, "Sandbox_test123_MyModule")
      true
  """
  def transform_source(source_code, sandbox_id, opts \\ []) do
    preserve_stdlib = Keyword.get(opts, :preserve_stdlib, true)
    sanitized_id = sanitize_sandbox_id(sandbox_id)
    # Create globally unique namespace to prevent conflicts
    unique_namespace = create_unique_namespace(sanitized_id)
    namespace_prefix = Keyword.get(opts, :namespace_prefix, unique_namespace)
    transform_modules = Keyword.get(opts, :transform_modules)

    try do
      # Parse the source code into AST
      case Code.string_to_quoted(source_code) do
        {:ok, ast} ->
          case validate_defmodule_blocks(ast) do
            :ok ->
              {transformed_ast, module_mapping} =
                transform_ast(ast, namespace_prefix, preserve_stdlib, transform_modules)

              cleaned_ast = remove_unused_aliases(transformed_ast)
              transformed_code = Macro.to_string(cleaned_ast)
              {:ok, transformed_code, module_mapping}

            {:error, line} ->
              {:error, {:parse_error, line, :missing_do, []}}
          end

        {:error, {line, error, token}} ->
          {:error, {:parse_error, line, error, token}}
      end
    rescue
      error ->
        {:error, {:transformation_error, error}}
    end
  end

  @doc """
  Extracts module names defined in a source file.
  """
  def extract_module_names(source_code) when is_binary(source_code) do
    case Code.string_to_quoted(source_code) do
      {:ok, ast} ->
        {_ast, names} =
          Macro.prewalk(ast, [], fn
            {:defmodule, _meta, [module_alias, _]} = node, acc ->
              {node, [module_alias_to_atom(module_alias) | acc]}

            node, acc ->
              {node, acc}
          end)

        {:ok, names |> Enum.reverse() |> Enum.uniq()}

      {:error, _reason} ->
        {:error, :parse_error}
    end
  rescue
    _ -> {:error, :parse_error}
  end

  @doc """
  Transforms a module name to include sandbox-specific prefix.

  ## Parameters
  - `module_name`: Original module name (atom or string)
  - `sandbox_id`: Unique identifier for the sandbox
  - `opts`: Transformation options

  ## Returns
  - Transformed module name as atom

  ## Examples
      iex> ModuleTransformer.transform_module_name(MyModule, "test123")
      :"Sandbox_test123_MyModule"
  """
  def transform_module_name(module_name, sandbox_id, opts \\ []) do
    sanitized_id = sanitize_sandbox_id(sandbox_id)
    # Create globally unique namespace to prevent conflicts
    unique_namespace = create_unique_namespace(sanitized_id)
    namespace_prefix = Keyword.get(opts, :namespace_prefix, unique_namespace)
    preserve_stdlib = Keyword.get(opts, :preserve_stdlib, true)

    module_str = to_string(module_name)

    # Don't transform standard library modules
    if preserve_stdlib and is_stdlib_module?(module_str) do
      module_name
    else
      :"#{namespace_prefix}_#{module_str}"
    end
  end

  @doc """
  Reverses module name transformation to get original name.

  ## Parameters
  - `transformed_name`: The transformed module name
  - `sandbox_id`: Unique identifier for the sandbox

  ## Returns
  - Original module name as atom, or the input if not transformed
  """
  def reverse_transform_module_name(transformed_name, sandbox_id) do
    sanitized_id = sanitize_sandbox_id(sandbox_id)
    namespace_prefix = "Sandbox_#{sanitized_id}_"
    transformed_str = to_string(transformed_name)

    if String.starts_with?(transformed_str, namespace_prefix) do
      original_name = String.replace_prefix(transformed_str, namespace_prefix, "")
      String.to_atom(original_name)
    else
      transformed_name
    end
  end

  @doc """
  Creates a module mapping registry for a sandbox.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox

  ## Returns
  - ETS table reference for the mapping registry
  """
  def create_module_registry(sandbox_id, opts \\ []) do
    table_name = module_registry_table_name(sandbox_id, opts)

    case :ets.whereis(table_name) do
      :undefined ->
        :ets.new(table_name, [:named_table, :public, :set, {:read_concurrency, true}])

      _existing ->
        # Clear existing table
        :ets.delete_all_objects(table_name)
        table_name
    end
  end

  @doc """
  Registers a module mapping in the sandbox registry.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `original_name`: Original module name
  - `transformed_name`: Transformed module name
  """
  def register_module_mapping(sandbox_id, original_name, transformed_name, opts \\ []) do
    table_name = module_registry_table_name(sandbox_id, opts)

    # Store both directions of the mapping
    :ets.insert(table_name, {original_name, transformed_name})
    :ets.insert(table_name, {transformed_name, original_name})

    prefixed_original = ensure_elixir_prefix(original_name)
    prefixed_transformed = ensure_elixir_prefix(transformed_name)

    if prefixed_original != original_name or prefixed_transformed != transformed_name do
      :ets.insert(table_name, {prefixed_original, prefixed_transformed})
      :ets.insert(table_name, {prefixed_transformed, prefixed_original})
    end

    Logger.debug("Registered module mapping: #{original_name} <-> #{transformed_name}")
  end

  @doc """
  Looks up a module mapping in the sandbox registry.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  - `module_name`: Module name to look up

  ## Returns
  - `{:ok, mapped_name}` if mapping exists
  - `:not_found` if no mapping exists
  """
  def lookup_module_mapping(sandbox_id, module_name, opts \\ []) do
    table_name = module_registry_table_name(sandbox_id, opts)

    try do
      case :ets.lookup(table_name, module_name) do
        [{^module_name, mapped_name}] -> {:ok, mapped_name}
        [] -> :not_found
      end
    rescue
      ArgumentError ->
        # Table doesn't exist
        :not_found
    end
  end

  @doc """
  Destroys the module registry for a sandbox.

  ## Parameters
  - `sandbox_id`: Unique identifier for the sandbox
  """
  def destroy_module_registry(sandbox_id, opts \\ []) do
    table_name = module_registry_table_name(sandbox_id, opts)

    case :ets.whereis(table_name) do
      :undefined ->
        :ok

      _table ->
        :ets.delete(table_name)
        Logger.debug("Destroyed module registry for sandbox: #{sandbox_id}")
    end
  end

  # Private functions

  defp transform_ast(ast, namespace_prefix, preserve_stdlib, transform_modules) do
    module_mapping = %{}

    {transformed_ast, final_mapping} =
      Macro.prewalk(ast, module_mapping, fn node, mapping ->
        transform_node(node, namespace_prefix, preserve_stdlib, transform_modules, mapping)
      end)

    {transformed_ast, final_mapping}
  end

  defp remove_unused_aliases(ast) do
    used_aliases = collect_used_aliases(ast)

    Macro.postwalk(ast, fn
      {:alias, _meta, _args} = node ->
        case prune_alias_node(node, used_aliases) do
          {:__block__, _, []} = empty_block -> empty_block
          updated_node -> updated_node
        end

      node ->
        node
    end)
  end

  defp prune_alias_node(
         {:alias, meta, [{{:., dot_meta, [module_alias, :{}]}, alias_meta, alias_children}]},
         used_aliases
       ) do
    kept_children = filter_alias_children(alias_children, used_aliases)

    if kept_children == [] do
      {:__block__, meta, []}
    else
      {:alias, meta, [{{:., dot_meta, [module_alias, :{}]}, alias_meta, kept_children}]}
    end
  end

  defp prune_alias_node(
         {:alias, meta,
          [{{:., dot_meta, [module_alias, :{}]}, alias_meta, alias_children}, opts]},
         used_aliases
       ) do
    kept_children = filter_alias_children(alias_children, used_aliases)

    if kept_children == [] do
      {:__block__, meta, []}
    else
      {:alias, meta, [{{:., dot_meta, [module_alias, :{}]}, alias_meta, kept_children}, opts]}
    end
  end

  defp prune_alias_node({:alias, meta, [module_alias]}, used_aliases) do
    if alias_name_used?(module_alias, used_aliases) do
      {:alias, meta, [module_alias]}
    else
      {:__block__, meta, []}
    end
  end

  defp prune_alias_node({:alias, meta, [module_alias, opts]}, used_aliases) do
    as = Keyword.get(opts, :as)

    if alias_name_used?(module_alias, used_aliases, as) do
      {:alias, meta, [module_alias, opts]}
    else
      {:__block__, meta, []}
    end
  end

  defp prune_alias_node(node, _used_aliases), do: node

  defp filter_alias_children(alias_children, used_aliases) do
    Enum.filter(alias_children, fn child ->
      alias_name_used?(child, used_aliases)
    end)
  end

  defp alias_name_used?(module_alias, used_aliases, as_override \\ nil) do
    alias_name =
      case as_override do
        nil ->
          module_alias_to_atom(module_alias) |> alias_name_from_module()

        override when is_atom(override) ->
          override

        override when is_binary(override) ->
          String.to_atom(override)

        override when is_tuple(override) ->
          module_alias_to_atom(override) |> alias_name_from_module()
      end

    MapSet.member?(used_aliases, alias_name)
  end

  defp alias_name_from_module(module_atom) when is_atom(module_atom) do
    module_atom
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
    |> String.split(".")
    |> List.last()
    |> String.to_atom()
  end

  defp collect_used_aliases(ast) do
    collect_used_aliases(ast, MapSet.new())
  end

  defp collect_used_aliases({:alias, _meta, _args}, used_aliases), do: used_aliases

  defp collect_used_aliases({:defmodule, _meta, [_module_alias, do_block]}, used_aliases) do
    collect_used_aliases(do_block, used_aliases)
  end

  defp collect_used_aliases({:__aliases__, _meta, [first | _]}, used_aliases)
       when is_atom(first) do
    MapSet.put(used_aliases, first)
  end

  defp collect_used_aliases(list, used_aliases) when is_list(list) do
    Enum.reduce(list, used_aliases, &collect_used_aliases/2)
  end

  defp collect_used_aliases(tuple, used_aliases) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(used_aliases, &collect_used_aliases/2)
  end

  defp collect_used_aliases(map, used_aliases) when is_map(map) do
    Enum.reduce(map, used_aliases, fn {key, value}, acc ->
      acc
      |> collect_used_aliases(key)
      |> collect_used_aliases(value)
    end)
  end

  defp collect_used_aliases(_other, used_aliases), do: used_aliases

  defp transform_node(
         {:defmodule, meta, [module_alias, do_block]},
         namespace_prefix,
         preserve_stdlib,
         transform_modules,
         mapping
       ) do
    original_name = module_alias_to_atom(module_alias)

    if already_namespaced?(original_name, namespace_prefix) or
         (preserve_stdlib and is_stdlib_module?(to_string(original_name))) or
         not should_transform?(
           original_name,
           namespace_prefix,
           preserve_stdlib,
           transform_modules
         ) do
      # Don't transform standard library modules
      {{:defmodule, meta, [module_alias, do_block]}, mapping}
    else
      transformed_name = :"#{namespace_prefix}_#{original_name}"
      transformed_alias = atom_to_module_alias(transformed_name)

      new_mapping = Map.put(mapping, original_name, transformed_name)

      {{:defmodule, meta, [transformed_alias, do_block]}, new_mapping}
    end
  end

  defp transform_node(
         {:alias, meta, [{{:., dot_meta, [module_alias, :{}]}, alias_meta, alias_children}]},
         namespace_prefix,
         preserve_stdlib,
         transform_modules,
         mapping
       ) do
    original_name = module_alias_to_atom(module_alias)

    if already_namespaced?(original_name, namespace_prefix) or
         (preserve_stdlib and is_stdlib_module?(to_string(original_name))) or
         not should_transform_prefix?(
           original_name,
           namespace_prefix,
           preserve_stdlib,
           transform_modules
         ) do
      {{:alias, meta, [{{:., dot_meta, [module_alias, :{}]}, alias_meta, alias_children}]},
       mapping}
    else
      transformed_name = :"#{namespace_prefix}_#{original_name}"
      transformed_alias = atom_to_module_alias(transformed_name)

      new_mapping = Map.put(mapping, original_name, transformed_name)

      {{:alias, meta, [{{:., dot_meta, [transformed_alias, :{}]}, alias_meta, alias_children}]},
       new_mapping}
    end
  end

  defp transform_node(
         {:alias, meta, [module_alias | rest]},
         namespace_prefix,
         preserve_stdlib,
         transform_modules,
         mapping
       ) do
    original_name = module_alias_to_atom(module_alias)

    if already_namespaced?(original_name, namespace_prefix) or
         (preserve_stdlib and is_stdlib_module?(to_string(original_name))) or
         not should_transform?(
           original_name,
           namespace_prefix,
           preserve_stdlib,
           transform_modules
         ) do
      # Don't transform standard library module aliases
      {{:alias, meta, [module_alias | rest]}, mapping}
    else
      transformed_name = :"#{namespace_prefix}_#{original_name}"
      transformed_alias = atom_to_module_alias(transformed_name)

      new_mapping = Map.put(mapping, original_name, transformed_name)

      {{:alias, meta, [transformed_alias | rest]}, new_mapping}
    end
  end

  defp transform_node(
         {:__aliases__, _meta, _parts} = module_alias,
         namespace_prefix,
         preserve_stdlib,
         transform_modules,
         mapping
       ) do
    original_name = module_alias_to_atom(module_alias)

    if already_namespaced?(original_name, namespace_prefix) or
         (preserve_stdlib and is_stdlib_module?(to_string(original_name))) or
         not should_transform?(
           original_name,
           namespace_prefix,
           preserve_stdlib,
           transform_modules
         ) do
      {module_alias, mapping}
    else
      transformed_name = :"#{namespace_prefix}_#{original_name}"
      transformed_alias = atom_to_module_alias(transformed_name)

      new_mapping = Map.put(mapping, original_name, transformed_name)

      {transformed_alias, new_mapping}
    end
  end

  defp transform_node(
         {{:., meta1, [module_alias, function]}, meta2, args},
         namespace_prefix,
         preserve_stdlib,
         transform_modules,
         mapping
       ) do
    # Transform module function calls like Module.function()
    case module_alias do
      {:__aliases__, _, _} ->
        original_name = module_alias_to_atom(module_alias)

        if already_namespaced?(original_name, namespace_prefix) or
             (preserve_stdlib and is_stdlib_module?(to_string(original_name))) or
             not should_transform?(
               original_name,
               namespace_prefix,
               preserve_stdlib,
               transform_modules
             ) do
          # Don't transform standard library module calls
          {{{:., meta1, [module_alias, function]}, meta2, args}, mapping}
        else
          transformed_name = :"#{namespace_prefix}_#{original_name}"
          transformed_alias = atom_to_module_alias(transformed_name)

          new_mapping = Map.put(mapping, original_name, transformed_name)

          {{{:., meta1, [transformed_alias, function]}, meta2, args}, new_mapping}
        end

      _ ->
        # Not a module alias, leave unchanged
        {{{:., meta1, [module_alias, function]}, meta2, args}, mapping}
    end
  end

  defp transform_node(node, _namespace_prefix, _preserve_stdlib, _transform_modules, mapping) do
    # For all other nodes, leave unchanged
    {node, mapping}
  end

  defp validate_defmodule_blocks(ast) do
    {_ast, result} =
      Macro.prewalk(ast, :ok, fn
        {:defmodule, meta, args} = node, :ok ->
          if valid_defmodule_args?(args) do
            {node, :ok}
          else
            {node, {:error, meta}}
          end

        node, acc ->
          {node, acc}
      end)

    case result do
      :ok -> :ok
      {:error, meta} -> {:error, meta[:line] || 0}
    end
  end

  defp valid_defmodule_args?([_module, args]) when is_list(args) do
    Keyword.keyword?(args) and Keyword.has_key?(args, :do)
  end

  defp valid_defmodule_args?(_args), do: false

  defp module_alias_to_atom({:__aliases__, _, parts}) do
    parts
    |> Enum.map_join(".", &to_string/1)
    |> String.to_atom()
  end

  defp module_alias_to_atom(atom) when is_atom(atom), do: atom

  defp atom_to_module_alias(atom) do
    parts =
      atom
      |> to_string()
      |> String.split(".")
      |> Enum.map(&String.to_atom/1)

    {:__aliases__, [], parts}
  end

  defp is_stdlib_module?(module_str) when is_binary(module_str) do
    # Standard library modules that should not be transformed
    stdlib_prefixes = [
      "Elixir.",
      "Kernel",
      "GenServer",
      "Agent",
      "Task",
      "Process",
      "System",
      "File",
      "Path",
      "String",
      "Enum",
      "Stream",
      "Map",
      "List",
      "Keyword",
      "Atom",
      "MapSet",
      "Tuple",
      "Integer",
      "Float",
      "Range",
      "Regex",
      "URI",
      "Base",
      "Code",
      "Module",
      "Application",
      "Logger",
      "Mix",
      "ExUnit",
      "IO",
      "Date",
      "DateTime",
      "NaiveDateTime",
      "Time",
      "Calendar",
      "Calendar.ISO",
      "Supervisor",
      "Registry",
      "DynamicSupervisor",
      "GenEvent",
      "Port",
      "Node"
    ]

    Enum.any?(stdlib_prefixes, fn prefix ->
      String.starts_with?(module_str, prefix)
    end)
  end

  defp already_namespaced?(module_name, namespace_prefix) do
    module_name
    |> to_string()
    |> String.starts_with?("#{namespace_prefix}_")
  end

  defp should_transform?(module_name, namespace_prefix, preserve_stdlib, transform_modules) do
    cond do
      already_namespaced?(module_name, namespace_prefix) ->
        false

      preserve_stdlib and is_stdlib_module?(to_string(module_name)) ->
        false

      match?(%MapSet{}, transform_modules) ->
        MapSet.member?(transform_modules, module_name)

      true ->
        true
    end
  end

  defp should_transform_prefix?(module_name, namespace_prefix, preserve_stdlib, transform_modules) do
    cond do
      already_namespaced?(module_name, namespace_prefix) ->
        false

      preserve_stdlib and is_stdlib_module?(to_string(module_name)) ->
        false

      match?(%MapSet{}, transform_modules) ->
        base = to_string(module_name) <> "."

        MapSet.member?(transform_modules, module_name) or
          Enum.any?(transform_modules, fn mod ->
            String.starts_with?(to_string(mod), base)
          end)

      true ->
        true
    end
  end

  @doc """
  Sanitizes a sandbox ID to create a valid Elixir identifier.

  Elixir module names must:
  - Start with an uppercase letter
  - Contain only alphanumeric characters and underscores
  - Not start with numbers after underscores

  ## Examples
      iex> ModuleTransformer.sanitize_sandbox_id("test-123")
      "Test123"
      
      iex> ModuleTransformer.sanitize_sandbox_id("my_complex-id-456")
      "MyComplexId456"
  """
  def sanitize_sandbox_id(sandbox_id) when is_binary(sandbox_id) do
    sandbox_id
    # Replace invalid characters with underscore
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    # Split on one or more underscores
    |> String.split(~r/[_]+/)
    # Remove empty parts
    |> Enum.reject(&(&1 == ""))
    # Capitalize each part and join with single underscores
    |> Enum.map_join("_", &String.capitalize/1)
    |> ensure_starts_with_letter()
  end

  def sanitize_sandbox_id(sandbox_id), do: sanitize_sandbox_id(to_string(sandbox_id))

  defp ensure_starts_with_letter(<<first::utf8, rest::binary>>) when first in ?0..?9 do
    # If starts with a number, prefix with 'S'
    "S" <> <<first::utf8, rest::binary>>
  end

  defp ensure_starts_with_letter(string) when byte_size(string) == 0 do
    # Empty string, use default
    "Sandbox"
  end

  defp ensure_starts_with_letter(<<first::utf8, rest::binary>>) when first in ?a..?z do
    # Starts with lowercase letter, make it uppercase
    String.upcase(<<first::utf8>>) <> rest
  end

  defp ensure_starts_with_letter(string) do
    # Already starts with uppercase letter or underscore, keep as is
    string
  end

  @doc """
  Creates a globally unique namespace for a sandbox to prevent module conflicts.

  This function creates a namespace that is unique across all sandboxes and
  test runs by incorporating a timestamp and unique identifier.

  ## Parameters
  - `sanitized_id`: The sanitized sandbox ID

  ## Returns
  - A globally unique namespace string

  ## Examples
      iex> namespace = ModuleTransformer.create_unique_namespace("Test123")
      iex> String.starts_with?(namespace, "Sandbox_Test123_")
      true
  """
  def create_unique_namespace(sanitized_id) do
    # Use a combination of timestamp and unique integer for global uniqueness
    timestamp = System.system_time(:millisecond)
    unique_id = System.unique_integer([:positive])

    # Create a shorter, but still unique suffix
    unique_suffix = :erlang.phash2({timestamp, unique_id, self()}) |> abs()

    "Sandbox_#{sanitized_id}_#{unique_suffix}"
  end

  defp ensure_elixir_prefix(module) when is_atom(module) do
    module_str = Atom.to_string(module)

    if String.starts_with?(module_str, "Elixir.") do
      module
    else
      String.to_atom("Elixir." <> module_str)
    end
  end

  defp module_registry_table_name(sandbox_id, opts) do
    prefix =
      case Keyword.get(opts, :table_prefix) do
        nil -> Config.table_prefix(:module_registry, opts)
        value -> value
      end

    :"#{to_string(prefix)}_#{sandbox_id}"
  end
end
