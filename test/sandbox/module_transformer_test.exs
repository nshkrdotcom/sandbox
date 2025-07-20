defmodule Sandbox.ModuleTransformerTest do
  use ExUnit.Case, async: true

  alias Sandbox.ModuleTransformer

  describe "transform_source/3" do
    test "transforms simple module definition" do
      source = """
      defmodule MyModule do
        def hello do
          :world
        end
      end
      """

      sandbox_id = "test123"

      assert {:ok, transformed_code, module_mapping} =
               ModuleTransformer.transform_source(source, sandbox_id)

      # Should contain transformed module name with unique suffix
      assert String.contains?(transformed_code, "Sandbox_Test123_")
      assert String.contains?(transformed_code, "_MyModule")

      # Should have module mapping
      assert Map.has_key?(module_mapping, :MyModule)
      transformed_name = module_mapping[:MyModule]
      assert String.starts_with?(to_string(transformed_name), "Sandbox_Test123_")
      assert String.ends_with?(to_string(transformed_name), "_MyModule")
    end

    test "preserves standard library modules" do
      source = """
      defmodule MyModule do
        def test_enum do
          Enum.map([1, 2, 3], &(&1 * 2))
        end
      end
      """

      sandbox_id = "test456"

      assert {:ok, transformed_code, _module_mapping} =
               ModuleTransformer.transform_source(source, sandbox_id)

      # Should NOT transform Enum (stdlib module)
      assert String.contains?(transformed_code, "Enum.map")
      refute String.contains?(transformed_code, "Sandbox_test456_Enum")

      # Should transform MyModule with unique suffix
      assert String.contains?(transformed_code, "Sandbox_Test456_")
      assert String.contains?(transformed_code, "_MyModule")
    end

    test "transforms module aliases and function calls" do
      source = """
      defmodule MyModule do
        alias OtherModule
        
        def test_call do
          OtherModule.some_function()
        end
      end
      """

      sandbox_id = "test789"

      assert {:ok, transformed_code, module_mapping} =
               ModuleTransformer.transform_source(source, sandbox_id)

      # Should transform both modules with unique suffix
      assert String.contains?(transformed_code, "Sandbox_Test789_")
      assert String.contains?(transformed_code, "_MyModule")
      assert String.contains?(transformed_code, "_OtherModule")

      # Should have mappings for both
      assert Map.has_key?(module_mapping, :MyModule)
      assert Map.has_key?(module_mapping, :OtherModule)

      # Verify transformed names follow pattern
      my_module_name = to_string(module_mapping[:MyModule])
      other_module_name = to_string(module_mapping[:OtherModule])
      assert String.starts_with?(my_module_name, "Sandbox_Test789_")
      assert String.ends_with?(my_module_name, "_MyModule")
      assert String.starts_with?(other_module_name, "Sandbox_Test789_")
      assert String.ends_with?(other_module_name, "_OtherModule")
    end

    test "handles parse errors gracefully" do
      source = """
      defmodule InvalidModule do
        def broken_func do # missing end
      """

      sandbox_id = "test_error"

      assert {:error, {:parse_error, _line, _error, _token}} =
               ModuleTransformer.transform_source(source, sandbox_id)
    end
  end

  describe "transform_module_name/3" do
    test "transforms regular module names" do
      result = ModuleTransformer.transform_module_name(:MyModule, "test123")
      result_str = to_string(result)
      assert String.starts_with?(result_str, "Sandbox_Test123_")
      assert String.ends_with?(result_str, "_MyModule")
    end

    test "preserves standard library modules" do
      result = ModuleTransformer.transform_module_name(:Enum, "test123")
      assert result == :Enum

      result = ModuleTransformer.transform_module_name(:GenServer, "test123")
      assert result == :GenServer
    end

    test "handles string module names" do
      result = ModuleTransformer.transform_module_name("MyModule", "test123")
      result_str = to_string(result)
      assert String.starts_with?(result_str, "Sandbox_Test123_")
      assert String.ends_with?(result_str, "_MyModule")
    end
  end

  describe "reverse_transform_module_name/2" do
    test "reverses transformed module names" do
      transformed = :Sandbox_Test123_MyModule
      result = ModuleTransformer.reverse_transform_module_name(transformed, "test123")
      assert result == :MyModule
    end

    test "leaves non-transformed names unchanged" do
      original = :Enum
      result = ModuleTransformer.reverse_transform_module_name(original, "test123")
      assert result == :Enum
    end
  end

  describe "module registry functions" do
    test "creates and manages module registry" do
      sandbox_id = "registry_test"

      # Create registry
      table = ModuleTransformer.create_module_registry(sandbox_id)
      assert is_reference(table) or is_atom(table)

      # Register mapping
      original = :MyModule
      transformed = :Sandbox_registry_test_MyModule

      ModuleTransformer.register_module_mapping(sandbox_id, original, transformed)

      # Lookup both directions
      assert {:ok, ^transformed} = ModuleTransformer.lookup_module_mapping(sandbox_id, original)
      assert {:ok, ^original} = ModuleTransformer.lookup_module_mapping(sandbox_id, transformed)

      # Lookup non-existent
      assert :not_found = ModuleTransformer.lookup_module_mapping(sandbox_id, :NonExistent)

      # Destroy registry
      ModuleTransformer.destroy_module_registry(sandbox_id)

      # After destruction, lookup should return not_found
      assert :not_found = ModuleTransformer.lookup_module_mapping(sandbox_id, original)
    end

    test "handles registry recreation" do
      sandbox_id = "recreation_test"

      # Create and populate registry
      ModuleTransformer.create_module_registry(sandbox_id)
      ModuleTransformer.register_module_mapping(sandbox_id, :ModA, :Sandbox_recreation_test_ModA)

      # Verify data exists
      assert {:ok, _} = ModuleTransformer.lookup_module_mapping(sandbox_id, :ModA)

      # Recreate registry (should clear existing data)
      ModuleTransformer.create_module_registry(sandbox_id)

      # Verify data is cleared
      assert :not_found = ModuleTransformer.lookup_module_mapping(sandbox_id, :ModA)

      # Cleanup
      ModuleTransformer.destroy_module_registry(sandbox_id)
    end
  end

  describe "sanitize_sandbox_id/1" do
    test "removes invalid characters and capitalizes parts" do
      assert ModuleTransformer.sanitize_sandbox_id("test-123") == "Test_123"
      assert ModuleTransformer.sanitize_sandbox_id("my_complex-id-456") == "My_Complex_Id_456"
      assert ModuleTransformer.sanitize_sandbox_id("simple") == "Simple"
    end

    test "handles numbers at the start" do
      assert ModuleTransformer.sanitize_sandbox_id("123test") == "S123test"
      assert ModuleTransformer.sanitize_sandbox_id("4-test-5") == "S4_Test_5"
    end

    test "handles edge cases" do
      assert ModuleTransformer.sanitize_sandbox_id("") == "Sandbox"
      assert ModuleTransformer.sanitize_sandbox_id("_test") == "Test"
      assert ModuleTransformer.sanitize_sandbox_id("Test") == "Test"
    end

    test "handles complex sandbox IDs from tests" do
      # Real examples from our tests
      assert ModuleTransformer.sanitize_sandbox_id("test-crash-8998") == "Test_Crash_8998"
      assert ModuleTransformer.sanitize_sandbox_id("concurrent-1-676") == "Concurrent_1_676"

      assert ModuleTransformer.sanitize_sandbox_id("test-security-high-8135") ==
               "Test_Security_High_8135"
    end
  end

  describe "integration with complex modules" do
    test "handles nested modules" do
      source = """
      defmodule Outer do
        defmodule Inner do
          def nested_function, do: :ok
        end
        
        def call_inner do
          Inner.nested_function()
        end
      end
      """

      sandbox_id = "nested_test"

      assert {:ok, transformed_code, module_mapping} =
               ModuleTransformer.transform_source(source, sandbox_id)

      # Should transform both outer and inner modules with unique suffix
      assert String.contains?(transformed_code, "Sandbox_Nested_Test_")
      assert String.contains?(transformed_code, "_Outer")
      assert String.contains?(transformed_code, "_Inner")

      # Should have mappings
      assert Map.has_key?(module_mapping, :Outer)
      outer_name = to_string(module_mapping[:Outer])
      assert String.starts_with?(outer_name, "Sandbox_Nested_Test_")
      assert String.ends_with?(outer_name, "_Outer")
    end

    test "handles modules with behaviours" do
      source = """
      defmodule MyGenServer do
        @behaviour GenServer
        use GenServer
        
        def init(state), do: {:ok, state}
      end
      """

      sandbox_id = "behaviour_test"

      assert {:ok, transformed_code, module_mapping} =
               ModuleTransformer.transform_source(source, sandbox_id)

      # Should transform the module but preserve GenServer references
      assert String.contains?(transformed_code, "Sandbox_Behaviour_Test_")
      assert String.contains?(transformed_code, "_MyGenServer")
      assert String.contains?(transformed_code, "@behaviour GenServer")
      assert String.contains?(transformed_code, "use GenServer")

      # Should not transform GenServer itself
      refute String.contains?(transformed_code, "Sandbox_behaviour_test_GenServer")

      assert Map.has_key?(module_mapping, :MyGenServer)
    end
  end
end
