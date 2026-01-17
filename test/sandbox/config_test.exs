defmodule Sandbox.ConfigTest do
  use Sandbox.TestCase

  alias Sandbox.Config

  setup do
    original_table_names = Application.get_env(:sandbox, :table_names)
    original_services = Application.get_env(:sandbox, :services)
    original_table_prefixes = Application.get_env(:sandbox, :table_prefixes)

    on_exit(fn ->
      restore_env(:table_names, original_table_names)
      restore_env(:services, original_services)
      restore_env(:table_prefixes, original_table_prefixes)
    end)

    :ok
  end

  test "table_names accepts keyword list from application env" do
    Application.put_env(:sandbox, :table_names, sandboxes: :custom_sandboxes)

    assert %{sandboxes: :custom_sandboxes} = Config.table_names()
  end

  test "table_names accepts keyword list override" do
    assert %{sandboxes: :override_sandboxes} =
             Config.table_names(table_names: [sandboxes: :override_sandboxes])
  end

  test "service_names accepts keyword list override" do
    assert %{manager: :custom_manager} =
             Config.service_names(services: [manager: :custom_manager])
  end

  test "table_prefixes accepts keyword list override" do
    assert %{virtual_code: "custom_code"} =
             Config.table_prefixes(table_prefixes: [virtual_code: "custom_code"])
  end

  defp restore_env(key, nil), do: Application.delete_env(:sandbox, key)
  defp restore_env(key, value), do: Application.put_env(:sandbox, key, value)
end
