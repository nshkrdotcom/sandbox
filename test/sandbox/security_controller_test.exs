defmodule Sandbox.SecurityControllerTest do
  use Sandbox.TestCase

  alias Sandbox.SecurityController

  setup do
    table_name = unique_atom("sandbox_security")
    controller_name = unique_atom("security_controller")

    cleanup_on_exit(fn ->
      if :ets.whereis(table_name) != :undefined do
        :ets.delete(table_name)
      end
    end)

    {:ok, pid} =
      setup_isolated_genserver(SecurityController, "security_controller",
        init_args: [table_name: table_name],
        name: controller_name
      )

    Process.unlink(pid)

    {:ok, %{controller: controller_name, table: table_name}}
  end

  test "authorize_operation allows operations under low profile", %{controller: controller} do
    sandbox_id = unique_id("security_allow")
    :ok = SecurityController.register_sandbox(sandbox_id, :low, server: controller)

    assert :ok =
             SecurityController.authorize_operation(sandbox_id, :file_write, server: controller)
  end

  test "authorize_operation rejects disallowed operations", %{controller: controller} do
    sandbox_id = unique_id("security_block")
    :ok = SecurityController.register_sandbox(sandbox_id, :high, server: controller)

    assert {:error, :operation_not_allowed} =
             SecurityController.authorize_operation(sandbox_id, :file_write, server: controller)
  end

  test "audit_event stores security entries", %{controller: controller, table: table} do
    sandbox_id = unique_id("security_audit")
    :ok = SecurityController.register_sandbox(sandbox_id, :medium, server: controller)

    :ok =
      SecurityController.audit_event(
        sandbox_id,
        :operation_blocked,
        %{operation: :file_write},
        server: controller
      )

    assert [{{^sandbox_id, _entry_id}, %{event: :operation_blocked}}] =
             :ets.match_object(table, {{sandbox_id, :_}, :_})
  end
end
