defmodule Sandbox.VirtualCodeTableTest do
  use ExUnit.Case, async: true

  alias Sandbox.VirtualCodeTable

  @moduletag :virtual_code_table

  # Sample BEAM data for testing (minimal valid BEAM file)
  @sample_beam_data <<
    "FOR1",
    0,
    0,
    0,
    60,
    "BEAM",
    "AtU8",
    0,
    0,
    0,
    28,
    0,
    0,
    0,
    16,
    0,
    0,
    0,
    16,
    0,
    0,
    0,
    0,
    "Code",
    0,
    0,
    0,
    12,
    0,
    0,
    0,
    16,
    0,
    0,
    0,
    0,
    "Atom",
    0,
    0,
    0,
    8,
    0,
    0,
    0,
    1,
    4,
    116,
    101,
    115,
    116
  >>

  describe "create_table/2" do
    test "creates a virtual code table successfully" do
      sandbox_id = "test_create_#{:rand.uniform(10000)}"

      assert {:ok, table_ref} = VirtualCodeTable.create_table(sandbox_id)
      # Named ETS tables return table name (atom)
      assert is_atom(table_ref)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns existing table if already created" do
      sandbox_id = "test_existing_#{:rand.uniform(10000)}"

      assert {:ok, table_ref1} = VirtualCodeTable.create_table(sandbox_id)
      assert {:ok, table_ref2} = VirtualCodeTable.create_table(sandbox_id)

      # Both should return the same table name
      assert table_ref1 == table_ref2

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "supports different table options" do
      sandbox_id = "test_options_#{:rand.uniform(10000)}"

      assert {:ok, _table_ref} =
               VirtualCodeTable.create_table(sandbox_id,
                 access: :protected,
                 read_concurrency: false,
                 write_concurrency: true
               )

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end
  end

  describe "load_module/4" do
    test "loads a module successfully" do
      sandbox_id = "test_load_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      assert :ok = VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "prevents loading duplicate modules by default" do
      sandbox_id = "test_duplicate_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      assert :ok = VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)

      assert {:error, {:module_already_loaded, :TestModule}} =
               VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "allows force reload of modules" do
      sandbox_id = "test_force_reload_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      assert :ok = VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)

      assert :ok =
               VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data,
                 force_reload: true
               )

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-existent table" do
      assert {:error, {:table_not_found, "non_existent"}} =
               VirtualCodeTable.load_module("non_existent", :TestModule, @sample_beam_data)
    end
  end

  describe "fetch_module/2" do
    test "fetches a loaded module successfully" do
      sandbox_id = "test_fetch_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      :ok = VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)

      assert {:ok, module_info} = VirtualCodeTable.fetch_module(sandbox_id, :TestModule)
      assert module_info.beam_data == @sample_beam_data
      assert is_integer(module_info.loaded_at)
      assert module_info.size == byte_size(@sample_beam_data)
      assert is_binary(module_info.checksum)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-loaded module" do
      sandbox_id = "test_fetch_missing_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      assert {:error, :not_loaded} = VirtualCodeTable.fetch_module(sandbox_id, :NonExistent)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-existent table" do
      assert {:error, :table_not_found} =
               VirtualCodeTable.fetch_module("non_existent", :TestModule)
    end
  end

  describe "list_modules/2" do
    test "lists all modules in the table" do
      sandbox_id = "test_list_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      :ok = VirtualCodeTable.load_module(sandbox_id, :ModuleA, @sample_beam_data)
      :ok = VirtualCodeTable.load_module(sandbox_id, :ModuleB, @sample_beam_data)

      assert {:ok, modules} = VirtualCodeTable.list_modules(sandbox_id)
      assert length(modules) == 2

      module_names = Enum.map(modules, & &1.name)
      assert :ModuleA in module_names
      assert :ModuleB in module_names

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "supports different sorting options" do
      sandbox_id = "test_list_sort_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      :ok = VirtualCodeTable.load_module(sandbox_id, :ZModule, @sample_beam_data)
      # Ensure different timestamps
      :timer.sleep(1)
      :ok = VirtualCodeTable.load_module(sandbox_id, :AModule, @sample_beam_data)

      # Sort by name (default)
      assert {:ok, modules_by_name} = VirtualCodeTable.list_modules(sandbox_id, sort_by: :name)
      assert [%{name: :AModule}, %{name: :ZModule}] = modules_by_name

      # Sort by loaded_at
      assert {:ok, modules_by_time} =
               VirtualCodeTable.list_modules(sandbox_id, sort_by: :loaded_at)

      assert [%{name: :ZModule}, %{name: :AModule}] = modules_by_time

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-existent table" do
      assert {:error, :table_not_found} =
               VirtualCodeTable.list_modules("non_existent")
    end
  end

  describe "unload_module/2" do
    test "unloads a module successfully" do
      sandbox_id = "test_unload_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      :ok = VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)
      assert {:ok, _module_info} = VirtualCodeTable.fetch_module(sandbox_id, :TestModule)

      assert :ok = VirtualCodeTable.unload_module(sandbox_id, :TestModule)
      assert {:error, :not_loaded} = VirtualCodeTable.fetch_module(sandbox_id, :TestModule)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-loaded module" do
      sandbox_id = "test_unload_missing_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      assert {:error, :not_loaded} = VirtualCodeTable.unload_module(sandbox_id, :NonExistent)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-existent table" do
      assert {:error, :table_not_found} =
               VirtualCodeTable.unload_module("non_existent", :TestModule)
    end
  end

  describe "destroy_table/1" do
    test "destroys a table successfully" do
      sandbox_id = "test_destroy_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      assert :ok = VirtualCodeTable.destroy_table(sandbox_id)
      assert {:error, :table_not_found} = VirtualCodeTable.fetch_module(sandbox_id, :TestModule)
    end

    test "returns error for non-existent table" do
      assert {:error, :table_not_found} = VirtualCodeTable.destroy_table("non_existent")
    end
  end

  describe "get_table_stats/1" do
    test "returns table statistics" do
      sandbox_id = "test_stats_#{:rand.uniform(10000)}"
      {:ok, table_ref} = VirtualCodeTable.create_table(sandbox_id)

      :ok = VirtualCodeTable.load_module(sandbox_id, :TestModule, @sample_beam_data)

      assert {:ok, stats} = VirtualCodeTable.get_table_stats(sandbox_id)
      assert stats.table_ref == table_ref
      assert stats.module_count == 1
      assert stats.total_size == byte_size(@sample_beam_data)
      assert is_integer(stats.memory_usage)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end

    test "returns error for non-existent table" do
      assert {:error, :table_not_found} = VirtualCodeTable.get_table_stats("non_existent")
    end
  end

  describe "concurrent operations" do
    test "handles concurrent access safely" do
      sandbox_id = "test_concurrent_#{:rand.uniform(10000)}"

      {:ok, _table_ref} =
        VirtualCodeTable.create_table(sandbox_id,
          read_concurrency: true,
          write_concurrency: true
        )

      # Create multiple tasks that load and fetch modules concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            module_name = :"ConcurrentModule#{i}"
            :ok = VirtualCodeTable.load_module(sandbox_id, module_name, @sample_beam_data)
            {:ok, _info} = VirtualCodeTable.fetch_module(sandbox_id, module_name)
            module_name
          end)
        end

      results = Task.await_many(tasks, 5000)
      assert length(results) == 10

      # Verify all modules were loaded
      {:ok, modules} = VirtualCodeTable.list_modules(sandbox_id)
      assert length(modules) == 10

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end
  end

  describe "integration with different data types" do
    test "handles various module names correctly" do
      sandbox_id = "test_module_names_#{:rand.uniform(10000)}"
      {:ok, _table_ref} = VirtualCodeTable.create_table(sandbox_id)

      module_names = [
        :SimpleModule,
        :"Complex.Module.Name",
        :Module_With_Underscores,
        :Module123WithNumbers
      ]

      # Load all modules
      Enum.each(module_names, fn module_name ->
        assert :ok = VirtualCodeTable.load_module(sandbox_id, module_name, @sample_beam_data)
      end)

      # Verify all can be fetched
      Enum.each(module_names, fn module_name ->
        assert {:ok, _info} = VirtualCodeTable.fetch_module(sandbox_id, module_name)
      end)

      # Cleanup
      VirtualCodeTable.destroy_table(sandbox_id)
    end
  end
end
