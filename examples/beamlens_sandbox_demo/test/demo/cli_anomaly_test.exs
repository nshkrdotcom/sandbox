defmodule Demo.CLIAnomalyTest do
  use ExUnit.Case, async: false

  @cli_module Module.concat(Demo, CLI)
  @skill_module Module.concat(Demo, SandboxSkill)

  setup do
    if Code.ensure_loaded?(@cli_module) and Code.ensure_loaded?(@skill_module) do
      Application.ensure_all_started(:beamlens_sandbox_demo)
      :ok
    else
      {:skip,
       "Demo modules not available. Run from examples/beamlens_sandbox_demo or use mix test.examples"}
    end
  end

  setup do
    on_exit(fn ->
      apply(@skill_module, :clear, [])
    end)

    :ok
  end

  test "run_anomaly uses live snapshot and accepts matching operator output" do
    operator_runner = fn skill, _opts ->
      snapshot = skill.snapshot()

      assert is_binary(snapshot[:sandbox_id])
      assert is_integer(snapshot[:processes])
      assert snapshot[:processes] > 10

      {:ok, %{state: :warning, summary: "process count elevated", notifications: 1}}
    end

    assert {:ok, %{operator: %{state: :warning, notifications: 1}}} =
             apply(@cli_module, :run_anomaly, [
               [
                 operator_runner: operator_runner,
                 client_registry: %{},
                 process_load: 25
               ]
             ])
  end

  test "run_anomaly fails when operator output contradicts process spike" do
    operator_runner = fn skill, _opts ->
      snapshot = skill.snapshot()
      assert is_integer(snapshot[:processes])
      assert snapshot[:processes] > 10

      {:ok, %{state: :healthy, summary: "sandbox stable", notifications: 0}}
    end

    assert {:error, {:anomaly_state_mismatch, _processes, 10, _state}} =
             apply(@cli_module, :run_anomaly, [
               [
                 operator_runner: operator_runner,
                 client_registry: %{},
                 process_load: 25
               ]
             ])
  end
end
