defmodule Demo.SandboxSkill do
  @moduledoc "Beamlens skill for sandbox info and resource usage."

  @behaviour Beamlens.Skill

  @sandbox_key {__MODULE__, :sandbox_id}

  def configure(sandbox_id) when is_binary(sandbox_id) do
    :persistent_term.put(@sandbox_key, sandbox_id)
    :ok
  end

  def clear do
    :persistent_term.erase(@sandbox_key)
    :ok
  end

  def title, do: "Sandbox"

  def description, do: "Sandbox: status and resource usage"

  def system_prompt do
    """
    You monitor a sandbox instance. Use the callbacks to read info and usage.
    Keep the summary short and call done() within 1-2 iterations.
    """
  end

  def snapshot do
    case sandbox_id() do
      nil -> %{error: "sandbox_id_not_configured"}
      sandbox_id -> snapshot_for(sandbox_id)
    end
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

  defp sandbox_id do
    case :persistent_term.get(@sandbox_key, nil) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp snapshot_for(sandbox_id) do
    case sandbox_resource_usage_for(sandbox_id) do
      %{error: _} = error -> error
      usage -> Map.put(usage, :sandbox_id, sandbox_id)
    end
  end

  defp sandbox_info do
    case sandbox_id() do
      nil -> %{error: "sandbox_id_not_configured"}
      sandbox_id -> sandbox_info_for(sandbox_id)
    end
  end

  defp sandbox_resource_usage do
    case sandbox_id() do
      nil -> %{error: "sandbox_id_not_configured"}
      sandbox_id -> sandbox_resource_usage_for(sandbox_id)
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
