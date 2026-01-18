defmodule Demo.CLIAnomalyTest do
  use ExUnit.Case, async: false

  alias Beamlens.Operator.Tools.{Done, SendNotification, SetState, TakeSnapshot}

  @cli_module Module.concat(Demo, CLI)
  @skill_module Module.concat(Demo, SandboxSkill)
  @store_module Module.concat(Demo.SandboxSkill, Store)

  setup do
    if Code.ensure_loaded?(@cli_module) and Code.ensure_loaded?(@skill_module) and
         Code.ensure_loaded?(@store_module) do
      Application.ensure_all_started(:beamlens_sandbox_demo)
      :ok
    else
      {:skip,
       "Demo modules not available. Run from examples/beamlens_sandbox_demo or use mix test.examples"}
    end
  end

  setup do
    on_exit(fn ->
      apply(@store_module, :clear, [])
    end)

    :ok
  end

  test "run_anomaly uses live snapshot and accepts matching operator output" do
    puck_client =
      Beamlens.Testing.mock_client([
        %TakeSnapshot{intent: "take_snapshot"},
        %SendNotification{
          intent: "send_notification",
          type: "process_spike",
          summary: "process count elevated",
          severity: :warning,
          snapshot_ids: ["latest"]
        },
        %SetState{
          intent: "set_state",
          state: :warning,
          reason: "process count above threshold"
        },
        %Done{intent: "done"}
      ])

    assert {:ok, %{operator: %{state: :warning, notifications: 1}}} =
             apply(@cli_module, :run_anomaly, [
               [
                 puck_client: puck_client,
                 process_load: 25
               ]
             ])
  end

  test "run_anomaly fails when operator output contradicts process spike" do
    puck_client =
      Beamlens.Testing.mock_client([
        %TakeSnapshot{intent: "take_snapshot"},
        %SetState{
          intent: "set_state",
          state: :healthy,
          reason: "process count normal"
        },
        %Done{intent: "done"}
      ])

    assert {:error, {:anomaly_state_mismatch, _processes, 10, _state}} =
             apply(@cli_module, :run_anomaly, [
               [
                 puck_client: puck_client,
                 process_load: 25
               ]
             ])
  end
end
