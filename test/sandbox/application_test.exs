defmodule Sandbox.ApplicationTest do
  use ExUnit.Case, async: true

  import Supertester.OTPHelpers
  import Supertester.Assertions

  describe "ETS table initialization" do
    test "creates all required ETS tables" do
      # Clean up any existing tables first
      Sandbox.Application.cleanup_ets_tables()

      # Initialize tables
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

      # Clean up
      Sandbox.Application.cleanup_ets_tables()
    end

    test "get_ets_info returns table information" do
      Sandbox.Application.cleanup_ets_tables()
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

      Sandbox.Application.cleanup_ets_tables()
    end

    test "cleanup_ets_tables removes all tables" do
      # Ensure tables exist first
      Sandbox.Application.cleanup_ets_tables()
      :ok = Sandbox.Application.init_ets_tables()

      # Verify tables exist
      assert :ets.whereis(:sandbox_registry) != :undefined

      # Clean up
      Sandbox.Application.cleanup_ets_tables()

      # Verify tables are gone
      assert :ets.whereis(:sandbox_registry) == :undefined
      assert :ets.whereis(:sandbox_modules) == :undefined
      assert :ets.whereis(:sandbox_resources) == :undefined
      assert :ets.whereis(:sandbox_security) == :undefined

      # Recreate tables for other tests
      :ok = Sandbox.Application.init_ets_tables()
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
