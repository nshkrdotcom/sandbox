defmodule Sandbox.RuntimeInjectionTest do
  use Sandbox.TestCase

  alias Sandbox.Manager
  alias Sandbox.ModuleVersionManager
  alias Sandbox.ProcessIsolator

  test "injects service names and ETS tables without cross-contamination" do
    sandbox_id = unique_id("inject")

    table_names =
      unique_atoms("inject_tables", [
        :sandboxes,
        :sandbox_monitors,
        :module_versions,
        :isolation_contexts
      ])

    service_names =
      unique_atoms("inject_services", [
        :manager,
        :module_version_manager,
        :process_isolator
      ])

    {:ok, mvm_pid} =
      ModuleVersionManager.start_link(
        name: service_names.module_version_manager,
        table_name: table_names.module_versions
      )

    {:ok, isolator_pid} =
      ProcessIsolator.start_link(
        name: service_names.process_isolator,
        table_name: table_names.isolation_contexts
      )

    {:ok, manager_pid} =
      Manager.start_link(
        name: service_names.manager,
        table_names: %{
          sandboxes: table_names.sandboxes,
          sandbox_monitors: table_names.sandbox_monitors
        },
        services: %{
          module_version_manager: service_names.module_version_manager,
          process_isolator: service_names.process_isolator
        }
      )

    on_exit(fn ->
      stop_genserver(manager_pid)
      stop_genserver(isolator_pid)
      stop_genserver(mvm_pid)
    end)

    assert :ets.whereis(table_names.sandboxes) != :undefined
    assert :ets.whereis(table_names.sandbox_monitors) != :undefined
    assert :ets.whereis(table_names.module_versions) != :undefined
    assert :ets.whereis(table_names.isolation_contexts) != :undefined

    :ets.insert(table_names.sandboxes, {sandbox_id, %{app_pid: self()}})

    assert {:ok, pid} = Manager.get_sandbox_pid(sandbox_id, server: service_names.manager)
    assert pid == self()
  end

  test "manager preserves existing ETS contents on init" do
    table_names = unique_atoms("persist_tables", [:sandboxes, :sandbox_monitors])
    manager_name = unique_atom("persist_manager")

    :ets.new(table_names.sandboxes, [:named_table, :set, :public])
    :ets.new(table_names.sandbox_monitors, [:named_table, :set, :public])

    :ets.insert(table_names.sandboxes, {"persisted", %{status: :running}})
    monitor_ref = make_ref()
    :ets.insert(table_names.sandbox_monitors, {monitor_ref, "persisted"})

    {:ok, manager_pid} =
      Manager.start_link(
        name: manager_name,
        table_names: %{
          sandboxes: table_names.sandboxes,
          sandbox_monitors: table_names.sandbox_monitors
        }
      )

    on_exit(fn -> stop_genserver(manager_pid) end)

    assert [{"persisted", _}] = :ets.lookup(table_names.sandboxes, "persisted")
    assert [{^monitor_ref, "persisted"}] = :ets.lookup(table_names.sandbox_monitors, monitor_ref)
  end

  test "module version manager uses injected ETS table" do
    table_name = unique_atom("module_versions")
    manager_name = unique_atom("mvm")

    {:ok, pid} = ModuleVersionManager.start_link(name: manager_name, table_name: table_name)
    Process.unlink(pid)

    on_exit(fn -> stop_genserver(pid) end)

    module = Module.concat(["InjectVersion", unique_id("mod")])

    {:module, ^module, beam_data, _} =
      Module.create(
        module,
        quote do
          def ping, do: :pong
        end,
        Macro.Env.location(__ENV__)
      )

    assert {:ok, 1} =
             ModuleVersionManager.register_module_version(
               "sandbox",
               module,
               beam_data,
               server: manager_name
             )

    assert :ets.lookup(table_name, {"sandbox", module}) != []

    assert {:ok, 1} =
             ModuleVersionManager.get_current_version("sandbox", module, server: manager_name)
  end

  test "process isolator preserves existing ETS contents on init" do
    table_name = unique_atom("isolation_contexts")
    isolator_name = unique_atom("isolator")

    :ets.new(table_name, [:named_table, :set, :public])
    :ets.insert(table_name, {"persisted", %{status: :running}})

    {:ok, pid} = ProcessIsolator.start_link(name: isolator_name, table_name: table_name)

    on_exit(fn -> stop_genserver(pid) end)

    assert [{"persisted", _}] = :ets.lookup(table_name, "persisted")
  end

  defp stop_genserver(pid) when is_pid(pid) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end
end
