defmodule Demo.SandboxRunnerTest do
  use ExUnit.Case, async: false

  alias Demo.SandboxRunner
  alias Demo.SandboxSkill

  setup do
    Application.ensure_all_started(:beamlens_sandbox_demo)
    %{sandbox_path: SandboxRunner.sandbox_path()}
  end

  test "create_sandbox returns running info", %{sandbox_path: sandbox_path} do
    sandbox_id = unique_id()
    result = SandboxRunner.create_sandbox(sandbox_id, sandbox_path)

    on_exit(fn -> SandboxRunner.destroy_sandbox(sandbox_id) end)

    assert {:ok, %{status: :running}} = result
  end

  test "hot_reload returns :hot_reloaded", %{sandbox_path: sandbox_path} do
    {_sandbox_id, result} = with_sandbox(sandbox_path, &SandboxRunner.hot_reload/1)

    assert {:ok, :hot_reloaded} = result
  end

  test "run_in_sandbox returns 42 after hot reload", %{sandbox_path: sandbox_path} do
    {_sandbox_id, result} =
      with_sandbox(sandbox_path, fn sandbox_id ->
        SandboxRunner.hot_reload(sandbox_id)
        SandboxRunner.run_in_sandbox(sandbox_id)
      end)

    assert {:ok, 42} = result
  end

  test "sandbox_skill snapshot reports sandbox id", %{sandbox_path: sandbox_path} do
    {sandbox_id, result} =
      with_sandbox(sandbox_path, fn sandbox_id ->
        SandboxSkill.configure(sandbox_id)
        SandboxSkill.snapshot()
      end)

    assert %{sandbox_id: ^sandbox_id} = result
  end

  defp with_sandbox(sandbox_path, fun) do
    sandbox_id = unique_id()
    {:ok, _info} = SandboxRunner.create_sandbox(sandbox_id, sandbox_path)

    try do
      {sandbox_id, fun.(sandbox_id)}
    after
      SandboxRunner.destroy_sandbox(sandbox_id)
      SandboxSkill.clear()
    end
  end

  defp unique_id do
    "demo-test-#{System.unique_integer([:positive])}"
  end
end
