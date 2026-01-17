defmodule Sandbox.ModuleTransformationIntegrationTest do
  use Sandbox.ManagerCase

  alias Sandbox.Manager

  setup do
    test_dir = create_temp_dir("transformation_test")
    write_mix_project(test_dir, "TransformTest", :transform_test)

    # Create a module that references another module (to test transformation)
    module_content = """
    defmodule TransformTest do
      def hello do
        Helper.format_greeting("world")
      end
    end

    defmodule Helper do
      def format_greeting(name) do
        "Hello, " <> name <> "!"
      end
    end
    """

    write_module_file(test_dir, "lib/transform_test.ex", module_content)

    on_exit(fn ->
      File.rm_rf!(test_dir)
    end)

    %{test_dir: test_dir}
  end

  test "creates sandbox with module transformation", %{test_dir: test_dir, manager: manager} do
    sandbox_id = unique_id("transform_integration_test")

    # Test supervisor module
    defmodule TestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    # Create sandbox with module transformation
    assert {:ok, sandbox_info} =
             Manager.create_sandbox(
               sandbox_id,
               TestSupervisor,
               sandbox_path: test_dir,
               server: manager
             )

    assert sandbox_info.id == sandbox_id
    assert sandbox_info.status == :running

    assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
  end

  test "sandbox with transformed modules doesn't conflict", %{
    test_dir: test_dir,
    manager: manager
  } do
    # This test would verify that multiple sandboxes can run the same modules
    # without conflicts due to module transformation

    sandbox_id_1 = unique_id("no_conflict_1")
    sandbox_id_2 = unique_id("no_conflict_2")

    defmodule NoConflictSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    # Create first sandbox
    {:ok, _info1} =
      Manager.create_sandbox(
        sandbox_id_1,
        NoConflictSupervisor,
        sandbox_path: test_dir,
        server: manager
      )

    # Create second sandbox with same code
    {:ok, _info2} =
      Manager.create_sandbox(
        sandbox_id_2,
        NoConflictSupervisor,
        sandbox_path: test_dir,
        server: manager
      )

    # Both should be running without module redefinition warnings
    await(
      fn ->
        case Manager.get_sandbox_info(sandbox_id_1, server: manager) do
          {:ok, info} -> info.status == :running
          _ -> false
        end
      end,
      timeout: 5000,
      description: "sandbox #{sandbox_id_1} ready"
    )

    await(
      fn ->
        case Manager.get_sandbox_info(sandbox_id_2, server: manager) do
          {:ok, info} -> info.status == :running
          _ -> false
        end
      end,
      timeout: 5000,
      description: "sandbox #{sandbox_id_2} ready"
    )

    assert {:ok, info1} = Manager.get_sandbox_info(sandbox_id_1, server: manager)
    assert {:ok, info2} = Manager.get_sandbox_info(sandbox_id_2, server: manager)

    assert info1.status == :running
    assert info2.status == :running

    # Clean up
    Manager.destroy_sandbox(sandbox_id_1, server: manager)
    Manager.destroy_sandbox(sandbox_id_2, server: manager)
  end
end
