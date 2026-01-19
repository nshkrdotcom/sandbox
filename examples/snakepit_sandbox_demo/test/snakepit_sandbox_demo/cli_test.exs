defmodule SnakepitSandboxDemo.CLITest do
  use ExUnit.Case, async: false

  alias Beamlens.Operator.Tools.{Done, SendNotification, SetState, TakeSnapshot}

  @cli_module Module.concat(SnakepitSandboxDemo, CLI)
  @store_module Module.concat(SnakepitSandboxDemo, Store)
  @runner_module Module.concat(SnakepitSandboxDemo, SandboxRunner)

  setup do
    if Code.ensure_loaded?(@cli_module) and Code.ensure_loaded?(@store_module) and
         Code.ensure_loaded?(@runner_module) do
      Application.ensure_all_started(:snakepit_sandbox_demo)
      :ok
    else
      {:skip,
       "Demo modules not available. Run from examples/snakepit_sandbox_demo or use mix test.examples"}
    end
  end

  setup do
    snakepit_path = apply(@runner_module, :snakepit_path, [])

    unless File.dir?(snakepit_path) do
      {:skip, "Snakepit path not found: #{snakepit_path}"}
    else
      on_exit(fn ->
        apply(@store_module, :clear, [])
      end)

      :ok
    end
  end

  test "run uses mock client and reports healthy" do
    puck_client =
      Beamlens.Testing.mock_client([
        %TakeSnapshot{intent: "take_snapshot"},
        %SetState{intent: "set_state", state: :healthy, reason: "session count normal"},
        %Done{intent: "done"}
      ])

    sandbox_id = "snakepit-test-#{System.unique_integer([:positive])}"

    assert {:ok, %{state: :healthy, notifications: 0}} =
             apply(@cli_module, :run, [[puck_client: puck_client, sandbox_id: sandbox_id]])
  end

  test "run_anomaly uses mock client and reports warning" do
    puck_client =
      Beamlens.Testing.mock_client([
        %TakeSnapshot{intent: "take_snapshot"},
        %SendNotification{
          intent: "send_notification",
          type: "session_spike",
          summary: "session count elevated",
          severity: :warning,
          snapshot_ids: ["latest"]
        },
        %SetState{intent: "set_state", state: :warning, reason: "session count above threshold"},
        %Done{intent: "done"}
      ])

    sandbox_id = "snakepit-test-#{System.unique_integer([:positive])}"

    assert {:ok, %{state: :warning, notifications: 1}} =
             apply(@cli_module, :run_anomaly, [
               [
                 puck_client: puck_client,
                 sandbox_id: sandbox_id,
                 seed_sessions: 12
               ]
             ])
  end
end
