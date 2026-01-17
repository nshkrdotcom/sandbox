defmodule Demo.SandboxAnomalySkill do
  @moduledoc "Beamlens skill focused on process spike detection."

  @behaviour Beamlens.Skill

  def configure(sandbox_id) when is_binary(sandbox_id) do
    Demo.SandboxSkill.configure(sandbox_id)
  end

  def clear do
    Demo.SandboxSkill.clear()
  end

  def title, do: "Sandbox Anomaly"

  def description, do: "Sandbox: detect process spikes and notify"

  def system_prompt do
    """
    You monitor a sandbox instance for process spikes. Use the callbacks to
    read info and usage. Do not use think.

    Use snapshot data from take_snapshot() as the source of truth. Ignore
    any counts provided in the context payload.

    If processes > 10:
      1) take_snapshot()
      2) send_notification(type: "process_spike", severity: "warning",
         summary: "process count elevated", snapshot_ids: ["<snapshot id>"])
      3) set_state("warning", "process count above threshold")
      4) done()

    If processes <= 10:
      set_state("healthy", "process count normal") then done().

    Keep responses short and complete within 4 iterations.
    """
  end

  def snapshot do
    Demo.SandboxSkill.snapshot()
  end

  def callbacks do
    Demo.SandboxSkill.callbacks()
  end

  def callback_docs do
    Demo.SandboxSkill.callback_docs()
  end
end
