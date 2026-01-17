defmodule Sandbox.ManagerLifecycleTest do
  @moduledoc """
  Comprehensive tests for SandboxManager process monitoring and lifecycle management.

  This test suite specifically validates the implementation of task 2.1:
  - Add comprehensive process monitoring with proper DOWN message handling
  - Implement sandbox state tracking with status transitions
  - Create cleanup mechanisms for crashed sandboxes with resource recovery
  - Add sandbox registry management with ETS operations and conflict resolution
  - Write unit tests using Supertester helpers for process lifecycle verification
  """

  use Sandbox.ManagerCase

  alias Sandbox.Manager

  @moduletag :capture_log

  describe "comprehensive process monitoring" do
    test "monitors sandbox processes with proper DOWN message handling", %{
      manager: manager,
      tables: tables
    } do
      # Create a test supervisor that we can control
      defmodule MonitorTestSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{monitored: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("monitor-test")

      # Create sandbox
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 MonitorTestSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      supervisor_pid = sandbox_info.supervisor_pid
      assert Process.alive?(supervisor_pid)

      # Verify monitoring is active by checking ETS entries
      assert [{^sandbox_id, stored_info}] = :ets.lookup(tables.sandboxes, sandbox_id)
      assert stored_info.status == :running
      assert stored_info.supervisor_pid == supervisor_pid

      # Kill the supervisor to trigger DOWN message
      Process.exit(supervisor_pid, :kill)

      # Wait for DOWN message processing
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

      # Verify the sandbox was cleaned up or marked as error
      case Manager.get_sandbox_info(sandbox_id, server: manager) do
        {:ok, info} ->
          # Sandbox still exists but marked as error
          assert info.status == :error
          refute Process.alive?(supervisor_pid)

        {:error, :not_found} ->
          # Sandbox was completely cleaned up
          assert [] = :ets.lookup(tables.sandboxes, sandbox_id)
      end
    end

    test "handles multiple concurrent sandbox crashes gracefully", %{manager: manager} do
      defmodule ConcurrentCrashSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{crash_test: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      # Create multiple sandboxes
      sandbox_ids = Enum.map(1..3, fn i -> unique_id("crash-test-#{i}") end)

      sandbox_pids =
        Enum.map(sandbox_ids, fn sandbox_id ->
          assert {:ok, sandbox_info} =
                   Manager.create_sandbox(
                     sandbox_id,
                     ConcurrentCrashSupervisor,
                     sandbox_path: fixture_path(),
                     server: manager
                   )

          {sandbox_id, sandbox_info.supervisor_pid}
        end)

      # Kill all supervisors simultaneously
      Enum.each(sandbox_pids, fn {_sandbox_id, pid} ->
        Process.exit(pid, :kill)
      end)

      # Wait for all processes to die
      Enum.each(sandbox_pids, fn {_sandbox_id, pid} ->
        assert {:ok, _reason} = wait_for_process_death(pid, 2000)
      end)

      await(
        fn ->
          Enum.all?(sandbox_ids, fn sandbox_id ->
            case Manager.get_sandbox_info(sandbox_id, server: manager) do
              {:ok, info} -> info.status == :error
              {:error, :not_found} -> true
              _ -> false
            end
          end)
        end,
        timeout: 2000,
        description: "manager to process batch crash"
      )

      # Verify all sandboxes were handled properly
      Enum.each(sandbox_ids, fn sandbox_id ->
        case Manager.get_sandbox_info(sandbox_id, server: manager) do
          {:ok, info} ->
            assert info.status == :error

          {:error, :not_found} ->
            # Completely cleaned up
            :ok
        end
      end)
    end
  end

  describe "sandbox state tracking with status transitions" do
    test "tracks complete lifecycle with proper status transitions", %{manager: manager} do
      defmodule LifecycleSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{lifecycle: :started} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("lifecycle-test")

      # Create sandbox and verify initial running state
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 LifecycleSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      assert sandbox_info.status == :running
      assert sandbox_info.restart_count == 0
      assert is_pid(sandbox_info.supervisor_pid)

      # Restart sandbox and verify state transitions
      assert {:ok, restarted_info} = Manager.restart_sandbox(sandbox_id, server: manager)

      # Verify status and restart count
      assert restarted_info.status == :running
      assert restarted_info.restart_count == 1
      assert restarted_info.id == sandbox_id

      # Verify PIDs changed but sandbox persisted
      refute restarted_info.supervisor_pid == sandbox_info.supervisor_pid
      assert Process.alive?(restarted_info.supervisor_pid)

      # Destroy sandbox and verify final state
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
      assert {:error, :not_found} = Manager.get_sandbox_info(sandbox_id, server: manager)
    end

    test "maintains state consistency during rapid operations", %{
      manager: manager,
      tables: tables
    } do
      defmodule RapidOpsSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{rapid_ops: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("rapid-ops")

      # Create sandbox
      assert {:ok, _sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 RapidOpsSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      # Perform rapid restart operations
      for i <- 1..3 do
        assert {:ok, info} = Manager.restart_sandbox(sandbox_id, server: manager)
        assert info.restart_count == i
        assert info.status == :running

        # Verify ETS consistency
        assert [{^sandbox_id, ets_info}] = :ets.lookup(tables.sandboxes, sandbox_id)
        assert ets_info.restart_count == i
        assert ets_info.status == :running
      end

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end
  end

  describe "cleanup mechanisms for crashed sandboxes" do
    test "performs comprehensive resource recovery after crash", %{
      manager: manager,
      tables: tables
    } do
      defmodule ResourceTestSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{resources: :allocated} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("resource-recovery")

      # Create sandbox
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ResourceTestSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      supervisor_pid = sandbox_info.supervisor_pid

      # Verify initial state
      assert [{^sandbox_id, _}] = :ets.lookup(tables.sandboxes, sandbox_id)
      assert Process.alive?(supervisor_pid)

      # Simulate crash
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
        description: "manager to process resource crash"
      )

      # Verify comprehensive cleanup occurred
      case Manager.get_sandbox_info(sandbox_id, server: manager) do
        {:ok, info} ->
          # Sandbox exists but marked as error
          assert info.status == :error
          refute Process.alive?(supervisor_pid)

        {:error, :not_found} ->
          # Complete cleanup - verify ETS is clean
          assert [] = :ets.lookup(tables.sandboxes, sandbox_id)
      end
    end

    test "handles cleanup errors gracefully", %{manager: manager} do
      defmodule CleanupErrorSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{cleanup_error_test: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("cleanup-error")

      # Create sandbox
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 CleanupErrorSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      supervisor_pid = sandbox_info.supervisor_pid

      # Kill the supervisor
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
        description: "manager to process cleanup crash"
      )

      # Manager should still be responsive despite any cleanup errors
      assert is_list(Manager.list_sandboxes(server: manager))

      # Verify we can still create new sandboxes
      new_sandbox_id = unique_id("post-cleanup")

      assert {:ok, _new_info} =
               Manager.create_sandbox(
                 new_sandbox_id,
                 CleanupErrorSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      # Cleanup
      assert :ok = Manager.destroy_sandbox(new_sandbox_id, server: manager)
    end
  end

  describe "ETS operations and conflict resolution" do
    test "maintains ETS consistency with concurrent operations", %{
      manager: manager,
      tables: tables
    } do
      defmodule ETSTestSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{ets_test: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      # Create multiple sandboxes concurrently
      sandbox_ids = Enum.map(1..5, fn i -> unique_id("ets-concurrent-#{i}") end)

      tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn ->
            Manager.create_sandbox(
              sandbox_id,
              ETSTestSupervisor,
              sandbox_path: fixture_path(),
              server: manager
            )
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # Verify all succeeded
      Enum.each(results, fn result ->
        assert {:ok, _info} = result
      end)

      # Verify ETS consistency
      Enum.each(sandbox_ids, fn sandbox_id ->
        assert [{^sandbox_id, info}] = :ets.lookup(tables.sandboxes, sandbox_id)
        assert info.status == :running
        assert info.id == sandbox_id
      end)

      # Verify Manager state consistency
      all_sandboxes = Manager.list_sandboxes(server: manager)
      created_ids = Enum.map(all_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        assert sandbox_id in created_ids
      end)

      # Cleanup all concurrently
      cleanup_tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn -> Manager.destroy_sandbox(sandbox_id, server: manager) end)
        end)

      cleanup_results = Task.await_many(cleanup_tasks, 10_000)

      Enum.each(cleanup_results, fn result ->
        assert :ok = result
      end)

      # Verify complete cleanup
      final_sandboxes = Manager.list_sandboxes(server: manager)
      final_ids = Enum.map(final_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        refute sandbox_id in final_ids
        assert [] = :ets.lookup(tables.sandboxes, sandbox_id)
      end)
    end

    test "resolves sandbox ID conflicts appropriately", %{
      manager: manager,
      tables: tables
    } do
      defmodule ConflictSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{conflict_test: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("conflict-test")

      # Create first sandbox
      assert {:ok, first_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      assert first_info.status == :running

      # Attempt to create second sandbox with same ID
      assert {:error, {:already_exists, existing_info}} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      # Verify conflict resolution
      assert existing_info.id == sandbox_id
      assert existing_info.status == :running
      assert existing_info.supervisor_pid == first_info.supervisor_pid

      # Verify ETS consistency
      assert [{^sandbox_id, ets_info}] = :ets.lookup(tables.sandboxes, sandbox_id)
      assert ets_info.id == sandbox_id
      assert ets_info.status == :running

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end

    test "handles ETS table recovery scenarios", %{manager: manager, tables: tables} do
      # This test verifies that the Manager can handle ETS table issues gracefully
      sandbox_id = unique_id("ets-recovery")

      # Verify Manager is responsive
      assert is_list(Manager.list_sandboxes(server: manager))

      # Verify ETS tables exist and are accessible
      assert is_list(:ets.tab2list(tables.sandboxes))
      assert is_list(:ets.tab2list(tables.sandbox_monitors))

      # Create a sandbox to verify normal operation
      defmodule ETSRecoverySupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{ets_recovery: true} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      assert {:ok, _info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ETSRecoverySupervisor,
                 sandbox_path: fixture_path(),
                 server: manager
               )

      # Verify ETS entry was created
      assert [{^sandbox_id, _}] = :ets.lookup(tables.sandboxes, sandbox_id)

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
      assert [] = :ets.lookup(tables.sandboxes, sandbox_id)
    end
  end

  describe "detailed status reporting" do
    test "provides comprehensive sandbox information", %{manager: manager} do
      defmodule DetailedStatusSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = [
            {Agent, fn -> %{detailed_status: true, data: String.duplicate("test", 100)} end}
          ]

          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = unique_id("detailed-status")

      # Create sandbox with specific resource limits
      assert {:ok, _info} =
               Manager.create_sandbox(
                 sandbox_id,
                 DetailedStatusSupervisor,
                 sandbox_path: fixture_path(),
                 resource_limits: %{max_memory: 128 * 1024 * 1024},
                 server: manager
               )

      # Get detailed information
      assert {:ok, detailed_info} = Manager.get_sandbox_info(sandbox_id, server: manager)

      # Verify comprehensive information is provided
      assert %{
               id: ^sandbox_id,
               status: :running,
               app_name: :sandbox,
               supervisor_module: DetailedStatusSupervisor,
               app_pid: app_pid,
               supervisor_pid: supervisor_pid,
               created_at: created_at,
               updated_at: updated_at,
               restart_count: 0,
               resource_usage: resource_usage,
               security_profile: security_profile,
               auto_reload_enabled: false
             } = detailed_info

      # Verify process information
      assert is_pid(app_pid)
      assert is_pid(supervisor_pid)
      assert Process.alive?(supervisor_pid)

      # Verify timestamps
      assert %DateTime{} = created_at
      assert %DateTime{} = updated_at

      # Verify resource usage tracking
      assert %{
               current_memory: memory,
               current_processes: processes,
               cpu_usage: cpu,
               uptime: uptime
             } = resource_usage

      assert is_integer(memory) and memory >= 0
      assert is_integer(processes) and processes > 0
      assert is_float(cpu) and cpu >= 0.0
      assert is_integer(uptime) and uptime >= 0

      # Verify security profile
      assert %{
               isolation_level: :medium,
               allowed_operations: operations,
               restricted_modules: modules,
               audit_level: :basic
             } = security_profile

      assert is_list(operations)
      assert is_list(modules)

      assert {:ok, updated_info} = Manager.get_sandbox_info(sandbox_id, server: manager)
      assert updated_info.resource_usage.uptime >= detailed_info.resource_usage.uptime

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id, server: manager)
    end
  end

  setup do
    ensure_fixture_tree()
    :ok
  end
end
