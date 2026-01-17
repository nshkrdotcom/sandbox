defmodule Sandbox.EtsIsolationDemoTest do
  use Sandbox.SerialCase

  alias Sandbox.Manager

  @moduletag :integration

  test "demonstrates ETS-based isolation capabilities (Phase 3)" do
    test_dir = create_temp_dir("ets_isolation_demo")
    on_exit(fn -> File.rm_rf!(test_dir) end)
    write_mix_project(test_dir, "EtsIsolationDemo", :ets_isolation_demo)

    module_content = """
    defmodule EtsDemo do
      def get_ets_info do
        %{
          pid: self(),
          node: node(),
          status: :running
        }
      end
    end
    """

    write_module_file(test_dir, "lib/ets_demo.ex", module_content)

    defmodule EtsIsolationTestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    sandbox_id = unique_id("ets_demo")

    assert {:ok, sandbox_info} =
             Manager.create_sandbox(
               sandbox_id,
               EtsIsolationTestSupervisor,
               sandbox_path: test_dir,
               isolation_mode: :ets,
               isolation_level: :medium
             )

    assert sandbox_info.status == :running
    assert :ok = Manager.destroy_sandbox(sandbox_id)
  end

  test "demonstrates all isolation modes working together" do
    test_dir = create_temp_dir("all_isolation_demo")
    on_exit(fn -> File.rm_rf!(test_dir) end)
    write_mix_project(test_dir, "AllIsolationDemo", :all_isolation_demo)

    module_content = """
    defmodule AllDemo do
      def get_info do
        %{
          pid: self(),
          node: node(),
          status: :running
        }
      end
    end
    """

    write_module_file(test_dir, "lib/all_demo.ex", module_content)

    defmodule AllIsolationTestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    isolation_modes = [:module, :process, :hybrid, :ets]

    Enum.each(isolation_modes, fn mode ->
      sandbox_id = unique_id("all_demo_#{mode}")

      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 AllIsolationTestSupervisor,
                 sandbox_path: test_dir,
                 isolation_mode: mode,
                 isolation_level: :medium
               )

      assert sandbox_info.status == :running
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end)
  end
end
