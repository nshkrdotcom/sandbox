defmodule Sandbox.ManagerTest do
  use Sandbox.ManagerCase

  alias Sandbox.Manager

  @moduletag :capture_log

  describe "process monitoring and lifecycle management" do
    test "creates sandbox with comprehensive monitoring", %{manager: manager, tables: tables} do
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
      sandbox_id = unique_id("test-monitoring")

      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 TestSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
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
      assert [{^sandbox_id, stored_info}] = :ets.lookup(tables.sandboxes, sandbox_id)
      assert stored_info.id == sandbox_id
      assert stored_info.status == :running

      # Verify monitoring is set up by checking the sandbox is tracked
      assert {:ok, current_info} = Manager.get_sandbox_info(sandbox_id, server: manager)
      assert current_info.status == :running

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end

    test "handles sandbox process crashes with proper cleanup", %{
      manager: manager,
      tables: tables
    } do
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

      sandbox_id = unique_id("test-crash")

      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 CrashingSupervisor,
                 sandbox_path: fixture_path(),
                 supervisor_module: CrashingSupervisor,
                 server: manager
               )

      supervisor_pid = sandbox_info.supervisor_pid
      assert Process.alive?(supervisor_pid)

      # Kill the supervisor to simulate crash
      Process.exit(supervisor_pid, :kill)

      assert {:ok, _reason} = wait_for_process_death(supervisor_pid, 2000)

      await(
        fn ->
          case Manager.get_sandbox_info(sandbox_id, server: manager) do
            {:ok, info} -> info.status == :error
            {:error, :not_found} -> true
            _ -> false
          end
        end,
        timeout: 2000,
        description: "manager to process sandbox crash"
      )

      # Verify cleanup occurred
      case Manager.get_sandbox_info(sandbox_id, server: manager) do
        {:ok, info} ->
          assert info.status == :error
          refute Process.alive?(supervisor_pid)

        {:error, :not_found} ->
          # Sandbox was completely cleaned up
          :ok
      end

      # Verify cleanup occurred in ETS
      assert [] = :ets.lookup(tables.sandboxes, sandbox_id)
    end

    test "tracks sandbox state transitions correctly", %{manager: manager} do
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

      sandbox_id = unique_id("test-states")

      # Create sandbox and verify initial state
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 StatefulSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      assert sandbox_info.status == :running
      assert sandbox_info.restart_count == 0

      # Restart sandbox and verify state transition
      assert {:ok, restarted_info} = Manager.restart_sandbox(sandbox_id, server: manager)
      assert restarted_info.status == :running
      assert restarted_info.restart_count == 1
      assert restarted_info.id == sandbox_id

      # Verify the PIDs changed but sandbox ID remained the same
      refute restarted_info.supervisor_pid == sandbox_info.supervisor_pid
      assert restarted_info.id == sandbox_info.id

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end

    test "handles concurrent sandbox operations safely", %{manager: manager} do
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
      sandbox_ids = Enum.map(1..5, fn i -> unique_id("concurrent-#{i}") end)

      tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn ->
            Manager.create_sandbox(
              sandbox_id,
              ConcurrentSupervisor,
              sandbox_path: fixture_path(),
              server: manager
            )
          end)
        end)

      results = Task.await_many(tasks, 5000)

      # Verify all sandboxes were created successfully
      Enum.each(results, fn result ->
        assert {:ok, _sandbox_info} = result
      end)

      # Verify all sandboxes are listed
      all_sandboxes = Manager.list_sandboxes(server: manager)
      created_ids = Enum.map(all_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        assert sandbox_id in created_ids
      end)

      # Cleanup all sandboxes concurrently
      cleanup_tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn -> Manager.destroy_sandbox(sandbox_id, server: manager) end)
        end)

      cleanup_results = Task.await_many(cleanup_tasks, 5000)

      # Verify all cleanups succeeded
      Enum.each(cleanup_results, fn result ->
        assert :ok = result
      end)

      # Verify no sandboxes remain
      final_sandboxes = Manager.list_sandboxes(server: manager)
      final_ids = Enum.map(final_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        refute sandbox_id in final_ids
      end)
    end

    test "provides detailed status reporting", %{manager: manager} do
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

      sandbox_id = unique_id("test-detailed")

      assert {:ok, _sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 DetailedSupervisor,
                 sandbox_path: fixture_path(),
                 resource_limits: %{max_memory: 64 * 1024 * 1024},
                 server: manager
               )

      # Verify detailed information is available
      assert {:ok, detailed_info} = Manager.get_sandbox_info(sandbox_id, server: manager)

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

      assert {:ok, updated_info} = Manager.get_sandbox_info(sandbox_id, server: manager)
      assert updated_info.resource_usage.uptime >= detailed_info.resource_usage.uptime

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end
  end

  describe "ETS operations and conflict resolution" do
    test "handles ETS conflicts gracefully", %{manager: manager} do
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

      sandbox_id = unique_id("test-conflict")

      # Create first sandbox
      assert {:ok, _first_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      # Attempt to create second sandbox with same ID
      assert {:error, {:already_exists, existing_info}} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      assert existing_info.id == sandbox_id
      assert existing_info.status == :running

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end

    test "maintains ETS consistency during failures", %{manager: manager, tables: tables} do
      # Use the existing manager from the application

      # Simulate ETS corruption by directly manipulating tables
      sandbox_id = unique_id("test-ets-consistency")

      # Insert invalid entry directly into ETS
      :ets.insert(tables.sandboxes, {sandbox_id, %{invalid: :entry}})

      # Verify manager handles this gracefully
      assert {:error, :not_found} = Manager.get_sandbox_info(sandbox_id, server: manager)

      # Verify manager handles invalid entries gracefully
      assert {:error, :not_found} = Manager.get_sandbox_info(sandbox_id, server: manager)
    end
  end

  setup do
    ensure_fixture_tree()
    :ok
  end
end
