defmodule Sandbox.ProcessIsolationDemoTest do
  use Sandbox.ManagerCase

  alias Sandbox.Manager

  @moduletag :integration

  test "demonstrates process isolation capabilities", %{manager: manager} do
    test_dir = create_temp_dir("process_isolation_demo")
    on_exit(fn -> File.rm_rf!(test_dir) end)
    write_mix_project(test_dir, "ProcessIsolationDemo", :process_isolation_demo)

    # Create a simple module
    module_content = """
    defmodule ProcessDemo do
      def get_process_info do
        %{
          pid: self(),
          node: node(),
          process_dictionary: Process.get()
        }
      end
    end
    """

    write_module_file(test_dir, "lib/process_demo.ex", module_content)

    # Test supervisor 
    defmodule ProcessIsolationTestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    # Test different isolation modes
    isolation_modes = [:module, :process, :hybrid]

    Enum.each(isolation_modes, fn mode ->
      sandbox_id = unique_id("process_demo_#{mode}")

      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ProcessIsolationTestSupervisor,
                 sandbox_path: test_dir,
                 isolation_mode: mode,
                 isolation_level: :medium,
                 server: manager
               )

      assert sandbox_info.status == :running
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end)
  end
end
