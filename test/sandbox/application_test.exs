defmodule Sandbox.ApplicationTest do
  use Sandbox.TestCase

  setup do
    table_names =
      unique_atoms("app_tables", [
        :sandbox_registry,
        :sandbox_modules,
        :sandbox_resources,
        :sandbox_security
      ])

    cleanup_on_exit(fn ->
      [
        table_names.sandbox_registry,
        table_names.sandbox_modules,
        table_names.sandbox_resources,
        table_names.sandbox_security
      ]
      |> Enum.each(fn table ->
        if :ets.whereis(table) != :undefined do
          :ets.delete(table)
        end
      end)
    end)

    {:ok, %{table_names: table_names}}
  end

  describe "ETS table initialization" do
    test "creates all required ETS tables", %{table_names: table_names} do
      # Initialize tables (idempotent operation)
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)

      # Verify all tables exist
      assert :ets.whereis(table_names.sandbox_registry) != :undefined
      assert :ets.whereis(table_names.sandbox_modules) != :undefined
      assert :ets.whereis(table_names.sandbox_resources) != :undefined
      assert :ets.whereis(table_names.sandbox_security) != :undefined

      # Verify table properties
      registry_info = :ets.info(table_names.sandbox_registry)
      assert registry_info[:type] == :set
      assert registry_info[:protection] == :public

      modules_info = :ets.info(table_names.sandbox_modules)
      assert modules_info[:type] == :bag
      assert modules_info[:protection] == :public
    end

    test "get_ets_info returns table information", %{table_names: table_names} do
      # Ensure tables exist (idempotent)
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)

      info = Sandbox.Application.get_ets_info(table_names: table_names)

      assert Map.has_key?(info, table_names.sandbox_registry)
      assert Map.has_key?(info, table_names.sandbox_modules)
      assert Map.has_key?(info, table_names.sandbox_resources)
      assert Map.has_key?(info, table_names.sandbox_security)

      registry_info = info[table_names.sandbox_registry]
      assert is_integer(registry_info.size)
      assert is_integer(registry_info.memory)
      assert registry_info.type == :set
    end

    test "init_ets_tables is idempotent", %{table_names: table_names} do
      # Call multiple times should not fail
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)

      # Verify tables still exist and work correctly
      assert :ets.whereis(table_names.sandbox_registry) != :undefined
      assert :ets.whereis(table_names.sandbox_modules) != :undefined
      assert :ets.whereis(table_names.sandbox_resources) != :undefined
      assert :ets.whereis(table_names.sandbox_security) != :undefined
    end
  end

  describe "application lifecycle" do
    test "stop does not delete ETS tables by default", %{table_names: table_names} do
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)
      :ets.insert(table_names.sandbox_registry, {:persisted, true})

      :ok = Sandbox.Application.stop(%{table_names: table_names, cleanup_ets_on_stop: false})

      assert :ets.whereis(table_names.sandbox_registry) != :undefined

      assert [{:persisted, true}] =
               :ets.lookup(table_names.sandbox_registry, :persisted)
    end

    test "stop deletes ETS tables when cleanup is enabled", %{table_names: table_names} do
      :ok = Sandbox.Application.init_ets_tables(table_names: table_names)
      :ets.insert(table_names.sandbox_registry, {:persisted, true})

      :ok = Sandbox.Application.stop(%{table_names: table_names, cleanup_ets_on_stop: true})

      assert :ets.whereis(table_names.sandbox_registry) == :undefined
    end
  end
end
