defmodule Sandbox.ResourceMonitorTest do
  use Sandbox.TestCase

  alias Sandbox.ResourceMonitor

  setup do
    table_name = unique_atom("sandbox_resources")
    monitor_name = unique_atom("resource_monitor")

    cleanup_on_exit(fn ->
      if :ets.whereis(table_name) != :undefined do
        :ets.delete(table_name)
      end
    end)

    {:ok, pid} =
      setup_isolated_genserver(ResourceMonitor, "resource_monitor",
        init_args: [table_name: table_name],
        name: monitor_name
      )

    Process.unlink(pid)

    {:ok, %{monitor: monitor_name}}
  end

  test "sample_usage returns usage for a registered sandbox", %{monitor: monitor} do
    sandbox_id = unique_id("resource")
    :ok = ResourceMonitor.register_sandbox(sandbox_id, self(), %{}, server: monitor)

    assert {:ok, %{memory: _memory, processes: _processes}} =
             ResourceMonitor.sample_usage(sandbox_id, server: monitor)
  end

  test "check_limits reports exceeded memory limits", %{monitor: monitor} do
    sandbox_id = unique_id("resource_limit")
    :ok = ResourceMonitor.register_sandbox(sandbox_id, self(), %{max_memory: 1}, server: monitor)

    assert {:error, {:limit_exceeded, [:max_memory]}} =
             ResourceMonitor.check_limits(sandbox_id, server: monitor)
  end

  test "unregister_sandbox removes entries", %{monitor: monitor} do
    sandbox_id = unique_id("resource_unregister")
    :ok = ResourceMonitor.register_sandbox(sandbox_id, self(), %{}, server: monitor)
    :ok = ResourceMonitor.unregister_sandbox(sandbox_id, server: monitor)

    assert {:error, :not_found} =
             ResourceMonitor.sample_usage(sandbox_id, server: monitor)
  end
end
