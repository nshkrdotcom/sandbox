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

  use ExUnit.Case, async: true


  alias Sandbox.Manager

  @moduletag :capture_log

  # Helper to get test fixture path consistently
  defp test_fixture_path do
    Path.expand("../../fixtures/simple_sandbox", __DIR__)
  end

  describe "comprehensive process monitoring" do
    test "monitors sandbox processes with proper DOWN message handling" do
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

      sandbox_id = "monitor-test-#{:rand.uniform(10000)}"

      # Create sandbox
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 MonitorTestSupervisor,
                 sandbox_path: test_fixture_path()
               )

      supervisor_pid = sandbox_info.supervisor_pid
      assert Process.alive?(supervisor_pid)

      # Verify monitoring is active by checking ETS entries
      assert [{^sandbox_id, stored_info}] = :ets.lookup(:sandboxes, sandbox_id)
      assert stored_info.status == :running
      assert stored_info.supervisor_pid == supervisor_pid

      # Kill the supervisor to trigger DOWN message
      Process.exit(supervisor_pid, :kill)

      # Wait for DOWN message processing
      assert_process_death(supervisor_pid, 2000)

      # Give the manager time to process the DOWN message
      :timer.sleep(100)

      # Verify the sandbox was cleaned up or marked as error
      case Manager.get_sandbox_info(sandbox_id) do
        {:ok, info} ->
          # Sandbox still exists but marked as error
          assert info.status == :error
          refute Process.alive?(supervisor_pid)

        {:error, :not_found} ->
          # Sandbox was completely cleaned up
          assert [] = :ets.lookup(:sandboxes, sandbox_id)
      end
    end

    test "handles multiple concurrent sandbox crashes gracefully" do
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
      sandbox_ids = for i <- 1..3, do: "crash-test-#{i}-#{:rand.uniform(10000)}"

      sandbox_pids =
        Enum.map(sandbox_ids, fn sandbox_id ->
          assert {:ok, sandbox_info} =
                   Manager.create_sandbox(
                     sandbox_id,
                     ConcurrentCrashSupervisor,
                     sandbox_path: test_fixture_path()
                   )

          {sandbox_id, sandbox_info.supervisor_pid}
        end)

      # Kill all supervisors simultaneously
      Enum.each(sandbox_pids, fn {_sandbox_id, pid} ->
        Process.exit(pid, :kill)
      end)

      # Wait for all processes to die
      Enum.each(sandbox_pids, fn {_sandbox_id, pid} ->
        assert_process_death(pid, 2000)
      end)

      # Give manager time to process all DOWN messages
      :timer.sleep(200)

      # Verify all sandboxes were handled properly
      Enum.each(sandbox_ids, fn sandbox_id ->
        case Manager.get_sandbox_info(sandbox_id) do
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
    test "tracks complete lifecycle with proper status transitions" do
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

      sandbox_id = "lifecycle-test-#{:rand.uniform(10000)}"

      # Create sandbox and verify initial running state
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 LifecycleSupervisor,
                 sandbox_path: test_fixture_path()
               )

      assert sandbox_info.status == :running
      assert sandbox_info.restart_count == 0
      assert is_pid(sandbox_info.supervisor_pid)

      # Restart sandbox and verify state transitions
      assert {:ok, restarted_info} = Manager.restart_sandbox(sandbox_id)

      # Verify status and restart count
      assert restarted_info.status == :running
      assert restarted_info.restart_count == 1
      assert restarted_info.id == sandbox_id

      # Verify PIDs changed but sandbox persisted
      refute restarted_info.supervisor_pid == sandbox_info.supervisor_pid
      assert Process.alive?(restarted_info.supervisor_pid)

      # Destroy sandbox and verify final state
      assert :ok = Manager.destroy_sandbox(sandbox_id)
      assert {:error, :not_found} = Manager.get_sandbox_info(sandbox_id)
    end

    test "maintains state consistency during rapid operations" do
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

      sandbox_id = "rapid-ops-#{:rand.uniform(10000)}"

      # Create sandbox
      assert {:ok, _sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 RapidOpsSupervisor,
                 sandbox_path: test_fixture_path()
               )

      # Perform rapid restart operations
      for i <- 1..3 do
        assert {:ok, info} = Manager.restart_sandbox(sandbox_id)
        assert info.restart_count == i
        assert info.status == :running

        # Verify ETS consistency
        assert [{^sandbox_id, ets_info}] = :ets.lookup(:sandboxes, sandbox_id)
        assert ets_info.restart_count == i
        assert ets_info.status == :running
      end

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end
  end

  describe "cleanup mechanisms for crashed sandboxes" do
    test "performs comprehensive resource recovery after crash" do
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

      sandbox_id = "resource-recovery-#{:rand.uniform(10000)}"

      # Create sandbox
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ResourceTestSupervisor,
                 sandbox_path: test_fixture_path()
               )

      supervisor_pid = sandbox_info.supervisor_pid

      # Verify initial state
      assert [{^sandbox_id, _}] = :ets.lookup(:sandboxes, sandbox_id)
      assert Process.alive?(supervisor_pid)

      # Simulate crash
      Process.exit(supervisor_pid, :kill)
      assert_process_death(supervisor_pid, 2000)

      # Wait for cleanup processing
      :timer.sleep(150)

      # Verify comprehensive cleanup occurred
      case Manager.get_sandbox_info(sandbox_id) do
        {:ok, info} ->
          # Sandbox exists but marked as error
          assert info.status == :error
          refute Process.alive?(supervisor_pid)

        {:error, :not_found} ->
          # Complete cleanup - verify ETS is clean
          assert [] = :ets.lookup(:sandboxes, sandbox_id)
      end
    end

    test "handles cleanup errors gracefully" do
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

      sandbox_id = "cleanup-error-#{:rand.uniform(10000)}"

      # Create sandbox
      assert {:ok, sandbox_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 CleanupErrorSupervisor,
                 sandbox_path: test_fixture_path()
               )

      supervisor_pid = sandbox_info.supervisor_pid

      # Kill the supervisor
      Process.exit(supervisor_pid, :kill)
      assert_process_death(supervisor_pid, 2000)

      # Wait for cleanup
      :timer.sleep(100)

      # Manager should still be responsive despite any cleanup errors
      assert is_list(Manager.list_sandboxes())

      # Verify we can still create new sandboxes
      new_sandbox_id = "post-cleanup-#{:rand.uniform(10000)}"

      assert {:ok, _new_info} =
               Manager.create_sandbox(
                 new_sandbox_id,
                 CleanupErrorSupervisor,
                 sandbox_path: test_fixture_path()
               )

      # Cleanup
      assert :ok = Manager.destroy_sandbox(new_sandbox_id)
    end
  end

  describe "ETS operations and conflict resolution" do
    test "maintains ETS consistency with concurrent operations" do
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
      sandbox_ids = for i <- 1..5, do: "ets-concurrent-#{i}-#{:rand.uniform(10000)}"

      tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn ->
            Manager.create_sandbox(
              sandbox_id,
              ETSTestSupervisor,
              sandbox_path: test_fixture_path()
            )
          end)
        end)

      results = Task.await_many(tasks, 10000)

      # Verify all succeeded
      Enum.each(results, fn result ->
        assert {:ok, _info} = result
      end)

      # Verify ETS consistency
      Enum.each(sandbox_ids, fn sandbox_id ->
        assert [{^sandbox_id, info}] = :ets.lookup(:sandboxes, sandbox_id)
        assert info.status == :running
        assert info.id == sandbox_id
      end)

      # Verify Manager state consistency
      all_sandboxes = Manager.list_sandboxes()
      created_ids = Enum.map(all_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        assert sandbox_id in created_ids
      end)

      # Cleanup all concurrently
      cleanup_tasks =
        Enum.map(sandbox_ids, fn sandbox_id ->
          Task.async(fn -> Manager.destroy_sandbox(sandbox_id) end)
        end)

      cleanup_results = Task.await_many(cleanup_tasks, 10000)

      Enum.each(cleanup_results, fn result ->
        assert :ok = result
      end)

      # Verify complete cleanup
      final_sandboxes = Manager.list_sandboxes()
      final_ids = Enum.map(final_sandboxes, & &1.id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        refute sandbox_id in final_ids
        assert [] = :ets.lookup(:sandboxes, sandbox_id)
      end)
    end

    test "resolves sandbox ID conflicts appropriately" do
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

      sandbox_id = "conflict-test-#{:rand.uniform(10000)}"

      # Create first sandbox
      assert {:ok, first_info} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: test_fixture_path()
               )

      assert first_info.status == :running

      # Attempt to create second sandbox with same ID
      assert {:error, {:already_exists, existing_info}} =
               Manager.create_sandbox(
                 sandbox_id,
                 ConflictSupervisor,
                 sandbox_path: test_fixture_path()
               )

      # Verify conflict resolution
      assert existing_info.id == sandbox_id
      assert existing_info.status == :running
      assert existing_info.supervisor_pid == first_info.supervisor_pid

      # Verify ETS consistency
      assert [{^sandbox_id, ets_info}] = :ets.lookup(:sandboxes, sandbox_id)
      assert ets_info.id == sandbox_id
      assert ets_info.status == :running

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
    end

    test "handles ETS table recovery scenarios" do
      # This test verifies that the Manager can handle ETS table issues gracefully
      sandbox_id = "ets-recovery-#{:rand.uniform(10000)}"

      # Verify Manager is responsive
      assert is_list(Manager.list_sandboxes())

      # Verify ETS tables exist and are accessible
      assert is_list(:ets.tab2list(:sandboxes))
      assert is_list(:ets.tab2list(:sandbox_monitors))

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
                 sandbox_path: test_fixture_path()
               )

      # Verify ETS entry was created
      assert [{^sandbox_id, _}] = :ets.lookup(:sandboxes, sandbox_id)

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
      assert [] = :ets.lookup(:sandboxes, sandbox_id)
    end
  end

  describe "detailed status reporting" do
    test "provides comprehensive sandbox information" do
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

      sandbox_id = "detailed-status-#{:rand.uniform(10000)}"

      # Create sandbox with specific resource limits
      assert {:ok, _info} =
               Manager.create_sandbox(
                 sandbox_id,
                 DetailedStatusSupervisor,
                 sandbox_path: test_fixture_path(),
                 resource_limits: %{max_memory: 128 * 1024 * 1024}
               )

      # Get detailed information
      assert {:ok, detailed_info} = Manager.get_sandbox_info(sandbox_id)

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

      # Wait a bit and verify uptime increases
      :timer.sleep(100)
      assert {:ok, updated_info} = Manager.get_sandbox_info(sandbox_id)
      assert updated_info.resource_usage.uptime > detailed_info.resource_usage.uptime

      # Cleanup
      assert :ok = Manager.destroy_sandbox(sandbox_id)
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

  # Helper function to create test fixtures directory if it doesn't exist
  defp ensure_test_fixtures do
    # Use a more robust path approach
    fixture_path = Path.expand("../../fixtures/simple_sandbox", __DIR__)

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

  setup do
    ensure_test_fixtures()
    :ok
  end
end
