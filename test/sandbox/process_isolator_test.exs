defmodule Sandbox.ProcessIsolatorTest do
  use Sandbox.TestCase

  alias Sandbox.ProcessIsolator

  @moduletag :process_isolation

  setup do
    table_name = unique_atom("isolation_contexts")
    isolator_name = unique_atom("process_isolator")

    cleanup_on_exit(fn ->
      if :ets.whereis(table_name) != :undefined do
        :ets.delete(table_name)
      end
    end)

    {:ok, pid} =
      setup_isolated_genserver(ProcessIsolator, "process_isolator",
        init_args: [table_name: table_name],
        name: isolator_name
      )

    Process.unlink(pid)

    {:ok, %{isolator: isolator_name}}
  end

  defmodule TestSupervisor do
    use Supervisor

    def start_link(opts \\ []) do
      Supervisor.start_link(__MODULE__, opts)
    end

    def init(_opts) do
      children = [
        {Agent, fn -> %{test: :process_isolation} end}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  describe "create_isolated_context/3" do
    test "creates isolated process context successfully", %{isolator: isolator} do
      sandbox_id = unique_id("process_test")

      assert {:ok, context} =
               ProcessIsolator.create_isolated_context(
                 sandbox_id,
                 TestSupervisor,
                 isolation_level: :medium,
                 server: isolator
               )

      assert context.sandbox_id == sandbox_id
      assert context.supervisor_module == TestSupervisor
      assert context.isolation_level == :medium
      assert context.status == :running
      assert is_pid(context.isolated_pid)
      assert Process.alive?(context.isolated_pid)

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
    end

    test "creates context with strict isolation level", %{isolator: isolator} do
      sandbox_id = unique_id("strict_test")

      assert {:ok, context} =
               ProcessIsolator.create_isolated_context(
                 sandbox_id,
                 TestSupervisor,
                 isolation_level: :strict,
                 resource_limits: %{max_memory: 32 * 1024 * 1024},
                 server: isolator
               )

      assert context.isolation_level == :strict
      assert context.resource_limits.max_memory == 32 * 1024 * 1024

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
    end

    test "prevents duplicate contexts", %{isolator: isolator} do
      sandbox_id = unique_id("duplicate_test")

      # Create first context
      assert {:ok, _context} =
               ProcessIsolator.create_isolated_context(
                 sandbox_id,
                 TestSupervisor,
                 server: isolator
               )

      # Try to create duplicate
      assert {:error, {:already_exists, ^sandbox_id}} =
               ProcessIsolator.create_isolated_context(
                 sandbox_id,
                 TestSupervisor,
                 server: isolator
               )

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
    end
  end

  describe "destroy_isolated_context/1" do
    test "destroys context successfully", %{isolator: isolator} do
      sandbox_id = unique_id("destroy_test")

      # Create context
      {:ok, context} =
        ProcessIsolator.create_isolated_context(
          sandbox_id,
          TestSupervisor,
          server: isolator
        )

      isolated_pid = context.isolated_pid
      assert Process.alive?(isolated_pid)

      # Destroy context
      assert :ok = ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)

      # Process should be terminated
      assert {:ok, _reason} = wait_for_process_death(isolated_pid, 2000)
      refute Process.alive?(isolated_pid)

      # Context should not be found
      await(
        fn ->
          match?(
            {:error, :not_found},
            ProcessIsolator.get_context_info(sandbox_id, server: isolator)
          )
        end,
        timeout: 2000,
        description: "isolated context removal"
      )
    end

    test "handles non-existent context gracefully", %{isolator: isolator} do
      assert {:error, :not_found} =
               ProcessIsolator.destroy_isolated_context("non_existent", server: isolator)
    end
  end

  describe "get_context_info/1" do
    test "returns context information", %{isolator: isolator} do
      sandbox_id = unique_id("info_test")

      # Create context
      {:ok, _context} =
        ProcessIsolator.create_isolated_context(
          sandbox_id,
          TestSupervisor,
          isolation_level: :relaxed,
          server: isolator
        )

      # Get info
      assert {:ok, info} = ProcessIsolator.get_context_info(sandbox_id, server: isolator)

      assert info.sandbox_id == sandbox_id
      assert info.supervisor_module == TestSupervisor
      assert info.isolation_level == :relaxed
      assert info.status == :running
      assert is_map(info.resource_usage)
      assert is_integer(info.resource_usage.memory)
      assert is_integer(info.resource_usage.uptime)

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
    end

    test "returns error for non-existent context", %{isolator: isolator} do
      assert {:error, :not_found} =
               ProcessIsolator.get_context_info("non_existent", server: isolator)
    end
  end

  describe "list_contexts/0" do
    test "lists all active contexts", %{isolator: isolator} do
      sandbox_ids = Enum.map(1..3, fn i -> unique_id("list_test_#{i}") end)

      # Create multiple contexts
      Enum.each(sandbox_ids, fn sandbox_id ->
        {:ok, _context} =
          ProcessIsolator.create_isolated_context(
            sandbox_id,
            TestSupervisor,
            server: isolator
          )
      end)

      # List contexts
      contexts = ProcessIsolator.list_contexts(server: isolator)

      # Should include our test contexts
      context_ids = Enum.map(contexts, & &1.sandbox_id)

      Enum.each(sandbox_ids, fn sandbox_id ->
        assert sandbox_id in context_ids
      end)

      # Cleanup
      Enum.each(sandbox_ids, fn sandbox_id ->
        ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
      end)
    end
  end

  describe "send_message_to_sandbox/3" do
    test "sends message to isolated process", %{isolator: isolator} do
      sandbox_id = unique_id("message_test")

      # Create context
      {:ok, _context} =
        ProcessIsolator.create_isolated_context(
          sandbox_id,
          TestSupervisor,
          server: isolator
        )

      # Send message
      assert :ok =
               ProcessIsolator.send_message_to_sandbox(sandbox_id, {:ping}, server: isolator)

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
    end

    test "returns error for non-existent sandbox", %{isolator: isolator} do
      assert {:error, :not_found} =
               ProcessIsolator.send_message_to_sandbox(
                 "non_existent",
                 {:test_message},
                 server: isolator
               )
    end
  end

  describe "process isolation behavior" do
    test "isolated processes are truly isolated", %{isolator: isolator} do
      sandbox_1 = unique_id("isolation_test_1")
      sandbox_2 = unique_id("isolation_test_2")

      # Create two isolated contexts
      {:ok, context1} =
        ProcessIsolator.create_isolated_context(
          sandbox_1,
          TestSupervisor,
          server: isolator
        )

      {:ok, context2} =
        ProcessIsolator.create_isolated_context(
          sandbox_2,
          TestSupervisor,
          server: isolator
        )

      # Processes should be different
      refute context1.isolated_pid == context2.isolated_pid

      # Both should be alive and running
      assert Process.alive?(context1.isolated_pid)
      assert Process.alive?(context2.isolated_pid)

      # Killing one should not affect the other
      Process.exit(context1.isolated_pid, :kill)
      assert {:ok, _reason} = wait_for_process_death(context1.isolated_pid, 2000)

      refute Process.alive?(context1.isolated_pid)
      assert Process.alive?(context2.isolated_pid)

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_2, server: isolator)
    end

    test "process crash is handled gracefully", %{isolator: isolator} do
      sandbox_id = unique_id("crash_test")

      # Create context
      {:ok, context} =
        ProcessIsolator.create_isolated_context(
          sandbox_id,
          TestSupervisor,
          server: isolator
        )

      isolated_pid = context.isolated_pid
      assert Process.alive?(isolated_pid)

      # Kill the process
      Process.exit(isolated_pid, :kill)

      assert {:ok, _reason} = wait_for_process_death(isolated_pid, 2000)

      # Context should be cleaned up automatically
      await(
        fn ->
          match?(
            {:error, :not_found},
            ProcessIsolator.get_context_info(sandbox_id, server: isolator)
          )
        end,
        timeout: 2000,
        description: "isolated context cleanup"
      )
    end
  end

  describe "resource limits" do
    test "applies resource limits correctly", %{isolator: isolator} do
      sandbox_id = unique_id("resource_test")

      resource_limits = %{
        max_memory: 64 * 1024 * 1024,
        max_processes: 500,
        max_execution_time: 60_000
      }

      # Create context with resource limits
      {:ok, context} =
        ProcessIsolator.create_isolated_context(
          sandbox_id,
          TestSupervisor,
          resource_limits: resource_limits,
          server: isolator
        )

      assert context.resource_limits.max_memory == resource_limits.max_memory
      assert context.resource_limits.max_processes == resource_limits.max_processes
      assert context.resource_limits.max_execution_time == resource_limits.max_execution_time

      # Cleanup
      ProcessIsolator.destroy_isolated_context(sandbox_id, server: isolator)
    end
  end
end
