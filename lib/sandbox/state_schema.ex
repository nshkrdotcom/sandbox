defmodule Sandbox.StateSchema do
  @moduledoc """
  Advanced state schema validation and migration support.

  This module provides comprehensive state schema validation, change detection,
  and migration support for complex state transformations during hot-reloads.
  """

  @type schema :: %{
          version: non_neg_integer(),
          fields: %{atom() => field_spec()},
          required_fields: [atom()],
          optional_fields: [atom()],
          transformations: %{non_neg_integer() => transformation()}
        }

  @type field_spec :: %{
          type: field_type(),
          default: any(),
          validator: function() | nil,
          transformer: function() | nil
        }

  @type field_type ::
          :atom
          | :string
          | :integer
          | :float
          | :boolean
          | :list
          | :map
          | :tuple
          | :pid
          | :reference
          | :any

  @type transformation :: %{
          from_version: non_neg_integer(),
          to_version: non_neg_integer(),
          transform_fn: function(),
          rollback_fn: function() | nil,
          description: String.t()
        }

  @type validation_result ::
          {:ok, :valid}
          | {:error, :invalid, [validation_error()]}

  @type validation_error :: %{
          field: atom(),
          error: :missing | :type_mismatch | :validation_failed,
          expected: any(),
          actual: any(),
          message: String.t()
        }

  @type migration_result ::
          {:ok, any()}
          | {:error, :migration_failed, String.t()}

  @doc """
  Creates a new state schema definition.
  """
  @spec new_schema(non_neg_integer(), keyword()) :: schema()
  def new_schema(version, opts \\ []) do
    %{
      version: version,
      fields: Keyword.get(opts, :fields, %{}),
      required_fields: Keyword.get(opts, :required_fields, []),
      optional_fields: Keyword.get(opts, :optional_fields, []),
      transformations: Keyword.get(opts, :transformations, %{})
    }
  end

  @doc """
  Adds a field specification to a schema.
  """
  @spec add_field(schema(), atom(), field_type(), keyword()) :: schema()
  def add_field(schema, field_name, field_type, opts \\ []) do
    field_spec = %{
      type: field_type,
      default: Keyword.get(opts, :default),
      validator: Keyword.get(opts, :validator),
      transformer: Keyword.get(opts, :transformer)
    }

    updated_fields = Map.put(schema.fields, field_name, field_spec)

    updated_schema = %{schema | fields: updated_fields}

    # Update required/optional fields lists
    cond do
      Keyword.get(opts, :required, false) ->
        %{updated_schema | required_fields: [field_name | schema.required_fields]}

      Keyword.get(opts, :optional, false) ->
        %{updated_schema | optional_fields: [field_name | schema.optional_fields]}

      true ->
        updated_schema
    end
  end

  @doc """
  Adds a transformation between schema versions.
  """
  @spec add_transformation(schema(), non_neg_integer(), non_neg_integer(), function(), keyword()) ::
          schema()
  def add_transformation(schema, from_version, to_version, transform_fn, opts \\ []) do
    transformation = %{
      from_version: from_version,
      to_version: to_version,
      transform_fn: transform_fn,
      rollback_fn: Keyword.get(opts, :rollback_fn),
      description:
        Keyword.get(opts, :description, "Transform from v#{from_version} to v#{to_version}")
    }

    transformations = Map.put(schema.transformations, {from_version, to_version}, transformation)
    %{schema | transformations: transformations}
  end

  @doc """
  Validates state against a schema.
  """
  @spec validate_state(any(), schema()) :: validation_result()
  def validate_state(state, schema) when is_map(state) do
    _errors = []

    # Check required fields
    missing_required =
      schema.required_fields
      |> Enum.filter(fn field -> not Map.has_key?(state, field) end)
      |> Enum.map(fn field ->
        %{
          field: field,
          error: :missing,
          expected: "required field",
          actual: :missing,
          message: "Required field #{field} is missing"
        }
      end)

    # Validate field types and custom validators
    field_errors =
      schema.fields
      |> Enum.flat_map(fn {field_name, field_spec} ->
        case Map.get(state, field_name) do
          # Already handled in required fields check
          nil -> []
          value -> validate_field_value(field_name, value, field_spec)
        end
      end)

    all_errors = missing_required ++ field_errors

    case all_errors do
      [] -> {:ok, :valid}
      errors -> {:error, :invalid, errors}
    end
  end

  def validate_state(_state, _schema) do
    {:error, :invalid,
     [
       %{
         field: :root,
         error: :type_mismatch,
         expected: :map,
         actual: :non_map,
         message: "State must be a map for schema validation"
       }
     ]}
  end

  @doc """
  Detects schema changes between two states.
  """
  @spec detect_schema_changes(any(), any()) :: [schema_change()]
  def detect_schema_changes(old_state, new_state) when is_map(old_state) and is_map(new_state) do
    old_keys = MapSet.new(Map.keys(old_state))
    new_keys = MapSet.new(Map.keys(new_state))

    added_fields = MapSet.difference(new_keys, old_keys) |> MapSet.to_list()
    removed_fields = MapSet.difference(old_keys, new_keys) |> MapSet.to_list()
    common_fields = MapSet.intersection(old_keys, new_keys) |> MapSet.to_list()

    type_changes =
      common_fields
      |> Enum.filter(fn field ->
        old_value = Map.get(old_state, field)
        new_value = Map.get(new_state, field)
        get_value_type(old_value) != get_value_type(new_value)
      end)
      |> Enum.map(fn field ->
        %{
          type: :type_change,
          field: field,
          old_type: get_value_type(Map.get(old_state, field)),
          new_type: get_value_type(Map.get(new_state, field))
        }
      end)

    changes = []

    changes =
      if added_fields != [],
        do: [%{type: :fields_added, fields: added_fields} | changes],
        else: changes

    changes =
      if removed_fields != [],
        do: [%{type: :fields_removed, fields: removed_fields} | changes],
        else: changes

    changes = type_changes ++ changes

    changes
  end

  def detect_schema_changes(_old_state, _new_state) do
    [%{type: :incompatible_types, message: "Cannot compare non-map states"}]
  end

  @doc """
  Migrates state using schema transformations.
  """
  @spec migrate_state(any(), non_neg_integer(), non_neg_integer(), schema()) :: migration_result()
  def migrate_state(state, from_version, to_version, schema) do
    case Map.get(schema.transformations, {from_version, to_version}) do
      nil ->
        # Try to find a path through intermediate versions
        find_migration_path(state, from_version, to_version, schema)

      transformation ->
        apply_transformation(state, transformation)
    end
  end

  @doc """
  Applies default values for missing fields based on schema.
  """
  @spec apply_defaults(map(), schema()) :: map()
  def apply_defaults(state, schema) when is_map(state) do
    schema.fields
    |> Enum.reduce(state, fn {field_name, field_spec}, acc ->
      maybe_apply_default(acc, field_name, field_spec.default)
    end)
  end

  def apply_defaults(state, _schema), do: state

  defp maybe_apply_default(state, field_name, default_value) do
    if Map.has_key?(state, field_name) or is_nil(default_value) do
      state
    else
      Map.put(state, field_name, default_value)
    end
  end

  # Private helper functions

  @type schema_change :: %{
          type: :fields_added | :fields_removed | :type_change | :incompatible_types,
          field: atom() | nil,
          fields: [atom()] | nil,
          old_type: atom() | nil,
          new_type: atom() | nil,
          message: String.t() | nil
        }

  defp validate_field_value(field_name, value, field_spec) do
    _errors = []

    # Type validation
    type_errors =
      if validate_field_type(value, field_spec.type) do
        []
      else
        [
          %{
            field: field_name,
            error: :type_mismatch,
            expected: field_spec.type,
            actual: get_value_type(value),
            message:
              "Field #{field_name} expected #{field_spec.type}, got #{get_value_type(value)}"
          }
        ]
      end

    # Custom validator
    validator_errors =
      case field_spec.validator do
        nil ->
          []

        validator_fn ->
          try do
            case validator_fn.(value) do
              true ->
                []

              false ->
                [
                  %{
                    field: field_name,
                    error: :validation_failed,
                    expected: "valid value",
                    actual: value,
                    message: "Field #{field_name} failed custom validation"
                  }
                ]

              {:error, message} ->
                [
                  %{
                    field: field_name,
                    error: :validation_failed,
                    expected: "valid value",
                    actual: value,
                    message: "Field #{field_name}: #{message}"
                  }
                ]
            end
          rescue
            error ->
              [
                %{
                  field: field_name,
                  error: :validation_failed,
                  expected: "valid value",
                  actual: value,
                  message: "Field #{field_name} validator error: #{inspect(error)}"
                }
              ]
          end
      end

    type_errors ++ validator_errors
  end

  defp validate_field_type(_value, :any), do: true
  defp validate_field_type(value, :atom) when is_atom(value), do: true
  defp validate_field_type(value, :string) when is_binary(value), do: true
  defp validate_field_type(value, :integer) when is_integer(value), do: true
  defp validate_field_type(value, :float) when is_float(value), do: true
  defp validate_field_type(value, :boolean) when is_boolean(value), do: true
  defp validate_field_type(value, :list) when is_list(value), do: true
  defp validate_field_type(value, :map) when is_map(value), do: true
  defp validate_field_type(value, :tuple) when is_tuple(value), do: true
  defp validate_field_type(value, :pid) when is_pid(value), do: true
  defp validate_field_type(value, :reference) when is_reference(value), do: true
  defp validate_field_type(_value, _type), do: false

  defp get_value_type(value) when is_atom(value), do: :atom
  defp get_value_type(value) when is_binary(value), do: :string
  defp get_value_type(value) when is_integer(value), do: :integer
  defp get_value_type(value) when is_float(value), do: :float
  defp get_value_type(value) when is_boolean(value), do: :boolean
  defp get_value_type(value) when is_list(value), do: :list
  defp get_value_type(value) when is_map(value), do: :map
  defp get_value_type(value) when is_tuple(value), do: :tuple
  defp get_value_type(value) when is_pid(value), do: :pid
  defp get_value_type(value) when is_reference(value), do: :reference
  defp get_value_type(_value), do: :unknown

  defp find_migration_path(state, from_version, to_version, schema) do
    # Simple implementation - could be enhanced with graph algorithms for complex paths
    intermediate_versions =
      schema.transformations
      |> Map.keys()
      |> Enum.filter(fn {from, _to} -> from == from_version end)
      |> Enum.map(fn {_from, to} -> to end)

    case Enum.find(intermediate_versions, fn version ->
           Map.has_key?(schema.transformations, {version, to_version})
         end) do
      nil ->
        {:error, :migration_failed,
         "No migration path from version #{from_version} to #{to_version}"}

      intermediate_version ->
        with {:ok, intermediate_state} <-
               migrate_state(state, from_version, intermediate_version, schema),
             {:ok, final_state} <-
               migrate_state(intermediate_state, intermediate_version, to_version, schema) do
          {:ok, final_state}
        else
          error -> error
        end
    end
  end

  defp apply_transformation(state, transformation) do
    new_state = transformation.transform_fn.(state)
    {:ok, new_state}
  rescue
    error ->
      {:error, :migration_failed, "Transformation failed: #{inspect(error)}"}
  end
end
