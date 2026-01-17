defmodule Sandbox.ModuleIsolationDemoTest do
  use Sandbox.ManagerCase

  alias Sandbox.Manager

  @moduletag :integration

  test "demonstrates reduced module conflicts with transformation", %{manager: manager} do
    test_dir = create_temp_dir("isolation_demo")
    on_exit(fn -> File.rm_rf!(test_dir) end)
    write_mix_project(test_dir, "IsolationDemo", :isolation_demo)

    # Create a module that would normally conflict
    module_content = """
    defmodule DemoModule do
      def get_identifier do
        "I am DemoModule from a sandbox"
      end
    end
    """

    write_module_file(test_dir, "lib/demo_module.ex", module_content)

    # Test supervisor 
    defmodule IsolationTestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    # Create multiple sandboxes with the same source code
    sandbox_ids = Enum.map(1..3, fn i -> unique_id("demo_sandbox_#{i}") end)

    Enum.each(sandbox_ids, fn sandbox_id ->
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 IsolationTestSupervisor,
                 sandbox_path: test_dir,
                 server: manager
               )

      assert sandbox_info.status == :running
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end)
  end
end
