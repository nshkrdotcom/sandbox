defmodule Demo.SandboxSkill do
  @moduledoc "Beamlens skill for sandbox info and resource usage."

  @behaviour Beamlens.Skill

  def title, do: "Sandbox"

  def description, do: "Sandbox: status and resource usage"

  def system_prompt do
    """
    You monitor a sandbox instance. Use the callbacks to read info and usage.
    Do not use think. Use snapshot data from take_snapshot() as the source of truth.

    If processes > 10:
      1) take_snapshot()
      2) send_notification(type: "process_spike", severity: "warning",
         summary: "process count elevated", snapshot_ids: ["<snapshot id>"])
      3) set_state("warning", "process count above threshold")
      4) done()

    If processes <= 10:
      take_snapshot() then set_state("healthy", "process count normal") then done().

    Keep responses short and complete within 4 iterations.
    """
  end

  def snapshot do
    with_sandbox_id(&snapshot_for/1)
  end

  def callbacks do
    %{
      "sandbox_info" => fn -> sandbox_info() end,
      "sandbox_resource_usage" => fn -> sandbox_resource_usage() end
    }
  end

  def callback_docs do
    """
    ### sandbox_info()
    Returns basic sandbox info: id, status, restart_count, created_at, resource_usage.

    ### sandbox_resource_usage()
    Returns memory/process usage: memory_bytes, processes, message_queue, uptime_ms.
    """
  end

  defp snapshot_for(sandbox_id) do
    case sandbox_resource_usage_for(sandbox_id) do
      %{error: _} = error -> error
      usage -> Map.put(usage, :sandbox_id, sandbox_id)
    end
  end

  defp sandbox_info do
    with_sandbox_id(&sandbox_info_for/1)
  end

  defp sandbox_resource_usage do
    with_sandbox_id(&sandbox_resource_usage_for/1)
  end

  defp with_sandbox_id(fun) do
    case Demo.SandboxSkill.Store.get_sandbox_id() do
      {:ok, sandbox_id} when is_binary(sandbox_id) ->
        fun.(sandbox_id)

      {:ok, nil} ->
        %{error: "sandbox_id_not_configured"}

      {:error, reason} ->
        %{error: format_reason(reason)}
    end
  end

  defp sandbox_info_for(sandbox_id) do
    case Sandbox.get_sandbox_info(sandbox_id) do
      {:ok, info} ->
        %{
          id: info.id,
          status: to_string(info.status),
          restart_count: info.restart_count,
          created_at: format_datetime(info.created_at),
          resource_usage: sanitize_usage(info.resource_usage)
        }

      {:error, reason} ->
        %{error: format_reason(reason)}
    end
  end

  defp sandbox_resource_usage_for(sandbox_id) do
    case Sandbox.resource_usage(sandbox_id) do
      {:ok, usage} -> sanitize_usage(usage)
      {:error, reason} -> %{error: format_reason(reason)}
    end
  end

  defp sanitize_usage(usage) do
    usage = if is_map(usage), do: usage, else: %{}

    %{
      memory_bytes: Map.get(usage, :current_memory),
      processes: Map.get(usage, :current_processes),
      message_queue: Map.get(usage, :message_queue),
      uptime_ms: Map.get(usage, :uptime)
    }
  end

  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(_), do: nil

  defp format_reason(reason) do
    reason
    |> inspect()
    |> String.replace("\n", " ")
  end
end
