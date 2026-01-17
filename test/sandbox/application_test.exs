defmodule Sandbox.ApplicationTest do
  use Sandbox.SerialCase

  # Clean ETS table contents before each test to ensure isolation
  # without causing race conditions on table existence
  setup do
    for table <- [:sandbox_registry, :sandbox_modules, :sandbox_resources, :sandbox_security] do
      case :ets.whereis(table) do
        :undefined -> :ok
        _ref -> :ets.delete_all_objects(table)
      end
    end

    :ok
  end

  describe "ETS table initialization" do
    test "creates all required ETS tables" do
      # Initialize tables (idempotent operation)
      :ok = Sandbox.Application.init_ets_tables()

      # Verify all tables exist
      assert :ets.whereis(:sandbox_registry) != :undefined
      assert :ets.whereis(:sandbox_modules) != :undefined
      assert :ets.whereis(:sandbox_resources) != :undefined
      assert :ets.whereis(:sandbox_security) != :undefined

      # Verify table properties
      registry_info = :ets.info(:sandbox_registry)
      assert registry_info[:type] == :set
      assert registry_info[:protection] == :public

      modules_info = :ets.info(:sandbox_modules)
      assert modules_info[:type] == :bag
      assert modules_info[:protection] == :public
    end

    test "get_ets_info returns table information" do
      # Ensure tables exist (idempotent)
      :ok = Sandbox.Application.init_ets_tables()

      info = Sandbox.Application.get_ets_info()

      assert Map.has_key?(info, :sandbox_registry)
      assert Map.has_key?(info, :sandbox_modules)
      assert Map.has_key?(info, :sandbox_resources)
      assert Map.has_key?(info, :sandbox_security)

      registry_info = info[:sandbox_registry]
      assert is_integer(registry_info.size)
      assert is_integer(registry_info.memory)
      assert registry_info.type == :set
    end

    test "init_ets_tables is idempotent" do
      # Call multiple times should not fail
      :ok = Sandbox.Application.init_ets_tables()
      :ok = Sandbox.Application.init_ets_tables()
      :ok = Sandbox.Application.init_ets_tables()

      # Verify tables still exist and work correctly
      assert :ets.whereis(:sandbox_registry) != :undefined
      assert :ets.whereis(:sandbox_modules) != :undefined
      assert :ets.whereis(:sandbox_resources) != :undefined
      assert :ets.whereis(:sandbox_security) != :undefined
    end
  end

  describe "application lifecycle" do
    test "application can start and stop" do
      # Note: This test assumes the application is not already running
      # In a real test environment, you might need to handle this differently

      case Application.start(:sandbox) do
        :ok ->
          # Verify ETS tables are created
          assert :ets.whereis(:sandbox_registry) != :undefined

          # Stop the application
          :ok = Application.stop(:sandbox)

        {:error, {:already_started, :sandbox}} ->
          # Application is already running, which is fine for this test
          :ok
      end
    end
  end
end
