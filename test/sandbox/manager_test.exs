defmodule Sandbox.ManagerTest do
  use ExUnit.Case, async: true

  alias Sandbox.Manager

  @moduletag :capture_log

  # Helper to get test fixture path consistently
  defp test_fixture_path do
    Path.expand("../../fixtures/simple_sandbox", __DIR__)
  end

  describe "process monitoring and lifecycle management" do
    test "creates sandbox with comprehensive monitoring" do
      # Use the existing manager from the application

      # Create a simple test supervisor
      defmodule TestSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{test: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      # Create sandbox with monitoring
      sandbox_id = "test-monitoring-#{:rand.uniform(10000)}"

      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 TestSupervisor,
                 sandbox_path: test_fixture_path()
               )

      # Verify sandbox info structure
      assert %{
               id: ^sandbox_id,
               status: :running,
               app_name: :sandbox,
               supervisor_module: TestSupervisor,
               app_pid: app_pid,
               supervisor_pid: supervisor_pid,
               restart_count: 0
             } = sandbox_info

      assert is_pid(app_pid)
      assert is_pid(supervisor_pid)
      assert Process.alive?(supervisor_pid)

      # Verify ETS entries
      assert [{^sandbox_id, stored_info}] = :ets.lookup(:sandboxes, sandbox_id)
      assert stored_info.id == sandbox_id
      assert stored_info.status == :running

      # Verify monitoring is set up by checking the sandbox is tracked
      assert {:ok, current_info} = Manager.get_sandbox_info(sandbox_id)
      assert current_info.status == :running

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end

    test "handles sandbox process crashes with proper cleanup" do
      # Use the existing manager from the application

      defmodule CrashingSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{crash_me: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end

        def crash_supervisor(name) do
          pid = Process.whereis(name)
          if pid, do: Process.exit(pid, :kill)
        end
      end

      sandbox_id = "test-crash-#{:rand.uniform(10000)}"
      _supervisor_name = :"crash_supervisor_#{:rand.uniform(10000)}"

      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 CrashingSupervisor,
                 sandbox_path: test_fixture_path(),
                 supervisor_module: CrashingSupervisor
               )

      supervisor_pid = sandbox_info.supervisor_pid
      assert Process.alive?(supervisor_pid)

      # Kill the supervisor to simulate crash
      Process.exit(supervisor_pid, :kill)

      # Wait for the process to die and DOWN message to be processed
      assert_process_death(supervisor_pid, 2000)

      # Give the manager a moment to process the DOWN message
      :timer.sleep(100)

      # Verify cleanup occurred
      case Manager.get_sandbox_info(sandbox_id) do
        {:ok, info} ->
          assert info.status == :error
          refute Process.alive?(supervisor_pid)

        {:error, :not_found} ->
          # Sandbox was completely cleaned up
          :ok
      end

      # Verify cleanup occurred in ETS
      assert [] = :ets.lookup(:sandboxes, sandbox_id)
    end

    test "tracks sandbox state transitions correctly" do
      # Use the existing manager from the application

      defmodule StatefulSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{state: :initial} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-states-#{:rand.uniform(10000)}"

      # Create sandbox and verify initial state
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 StatefulSupervisor,
                 sandbox_path: test_fixture_path()
               )

      assert sandbox_info.status == :running
      assert sandbox_info.restart_count == 0

      # Restart sandbox and verify state transition
      assert {:ok, restarted_info} = Manager.restart_sandbox(sandbox_id)
      assert restarted_info.status == :running
      assert restarted_info.restart_count == 1
      assert restarted_info.id == sandbox_id

      # Verify the PIDs changed but sandbox ID remained the same
      refute restarted_info.supervisor_pid == sandbox_info.supervisor_pid
      assert restarted_info.id == sandbox_info.id

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end

    test "handles concurrent sandbox operations safely" do
      # Use the existing manager from the application

      defmodule ConcurrentSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{concurrent: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      # Create multiple sandboxes concurrently
      sandbox_ids = for i <- 1..5, do: "concurrent-#{i}-#{:rand.uniform(10000)}"

      tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn ->
            Manager.create_sandbox(
              sandbox_id,
              ConcurrentSupervisor,
              sandbox_path: test_fixture_path()
            )
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # Verify all sandboxes were created successfully
      Enum.each(results, fn result ->
        assert {:ok, _sandbox_info} = result
      end)

      # Verify all sandboxes are listed
      all_sandboxes = Manager.list_sandboxes()
      created_ids = Enum.map(all_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        assert sandbox_id in created_ids
      end)

      # Cleanup all sandboxes concurrently
      cleanup_tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn -> Manager.destroy_sandbox(sandbox_id) end)
        end)

      cleanup_results = Task.await_many(cleanup_tasks, 5000)

      # Verify all cleanups succeeded
      Enum.each(cleanup_results, fn result ->
        assert :ok = result
      end)

      # Verify no sandboxes remain
      final_sandboxes = Manager.list_sandboxes()
      final_ids = Enum.map(final_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        refute sandbox_id in final_ids
      end)
    end

    test "provides detailed status reporting" do
      # Use the existing manager from the application

      defmodule DetailedSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{detailed: true, data: String.duplicate("x", 1000)} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-detailed-#{:rand.uniform(10000)}"

      assert {:ok, _sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 DetailedSupervisor,
                 sandbox_path: test_fixture_path(),
                 resource_limits: %{max_memory: 64 * 1024 * 1024}
               )

      # Verify detailed information is available
      assert {:ok, detailed_info} = Manager.get_sandbox_info(sandbox_id)

      assert %{
               id: ^sandbox_id,
               status: :running,
               resource_usage: %{
                 current_memory: memory,
                 current_processes: processes,
                 uptime: uptime
               },
               security_profile: %{
                 isolation_level: :medium
               }
             } = detailed_info

      assert is_integer(memory) and memory > 0
      assert is_integer(processes) and processes > 0
      assert is_integer(uptime) and uptime >= 0

      # Wait a bit and verify uptime increases
      :timer.sleep(100)
      assert {:ok, updated_info} = Manager.get_sandbox_info(sandbox_id)
      assert updated_info.resource_usage.uptime > detailed_info.resource_usage.uptime

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end
  end

  describe "ETS operations and conflict resolution" do
    test "handles ETS conflicts gracefully" do
      # Use the existing manager from the application

      defmodule ConflictSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-conflict-#{:rand.uniform(10000)}"

      # Create first sandbox
      assert {:ok, _first_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: test_fixture_path()
               )

      # Attempt to create second sandbox with same ID
      assert {:error, {:already_exists, existing_info}} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: test_fixture_path()
               )

      assert existing_info.id == sandbox_id
      assert existing_info.status == :running

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end

    test "maintains ETS consistency during failures" do
      # Use the existing manager from the application

      # Simulate ETS corruption by directly manipulating tables
      sandbox_id = "test-ets-consistency-#{:rand.uniform(10000)}"

      # Insert invalid entry directly into ETS
      :ets.insert(:sandboxes, {sandbox_id, %{invalid: :entry}})

      # Verify manager handles this gracefully
      assert {:error, :not_found} = Manager.get_sandbox_info(sandbox_id)

      # Verify manager handles invalid entries gracefully
      assert {:error, :not_found} = Manager.get_sandbox_info(sandbox_id)
    end
  end

  # Helper function to create test fixtures directory if it doesn't exist
  defp ensure_test_fixtures do
    fixture_path = test_fixture_path()

    unless File.exists?(fixture_path) do
      File.mkdir_p!(fixture_path)
      File.mkdir_p!(Path.join(fixture_path, "lib"))

      # Create a simple mix.exs
      mix_content = """
      defmodule SimpleSandbox.MixProject do
        use Mix.Project

        def project do
          [
            app: :simple_sandbox,
            version: "0.1.0",
            elixir: "~> 1.14"
          ]
        end

        def application do
          [
            extra_applications: [:logger]
          ]
        end
      end
      """

      File.write!(Path.join(fixture_path, "mix.exs"), mix_content)

      # Create a simple module
      module_content = """
      defmodule SimpleSandbox do
        def hello do
          :world
        end
      end
      """

      File.write!(Path.join([fixture_path, "lib", "simple_sandbox.ex"]), module_content)
    end
  end

  # Helper function to wait for process death
  defp assert_process_death(pid, timeout) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} ->
        :ok
    after
      timeout ->
        Process.demonitor(ref, [:flush])
        flunk("Process #{inspect(pid)} did not die within #{timeout}ms")
    end
  end

  setup do
    ensure_test_fixtures()
    :ok
  end
end
