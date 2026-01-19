defmodule SnakepitSandboxDemo.SandboxSkill do
  @moduledoc "Beamlens skill for sandbox and Snakepit health."

  @behaviour Beamlens.Skill

  @session_warning_threshold 10

  def title, do: "Snakepit Sandbox"

  def description, do: "Sandbox and Snakepit session health"

  def system_prompt do
    """
    You monitor a sandboxed Snakepit instance. Use the callbacks to read info and usage.
    Do not use think. It is unavailable. Use snapshot data from take_snapshot() as the source of truth.

    If snakepit.current_sessions is nil or snakepit.error is present:
      set_state("observing", "session stats unavailable") then done().

    If snakepit.current_sessions > #{@session_warning_threshold}:
      1) take_snapshot()
      2) If snakepit.pool.error is present:
           send_notification(type: "session_spike", severity: "warning",
             summary: "session count elevated; pool stats unavailable", snapshot_ids: ["latest"])
         Else if snakepit.pool.queued > 0 or snakepit.pool.pool_saturated > 0
           or snakepit.pool.busy >= snakepit.pool.workers:
           send_notification(type: "session_spike", severity: "warning",
             summary: "session count elevated; pool under pressure (queued=snakepit.pool.queued, busy=snakepit.pool.busy/snakepit.pool.workers)",
             snapshot_ids: ["latest"])
         Else:
           send_notification(type: "session_spike", severity: "warning",
             summary: "session count elevated", snapshot_ids: ["latest"])
      3) set_state("warning", "session count above threshold")
      4) done()

    If snakepit.current_sessions <= #{@session_warning_threshold}:
      take_snapshot() then set_state("healthy", "session count normal") then done().

    Keep responses short and complete within 4 iterations.
    """
  end

  def snapshot do
    with_sandbox_id(&snapshot_for/1)
  end

  def callbacks do
    %{
      "sandbox_info" => fn -> sandbox_info() end,
      "sandbox_resource_usage" => fn -> sandbox_resource_usage() end,
      "snakepit_session_stats" => fn -> snakepit_session_stats() end,
      "snakepit_pool_stats" => fn -> snakepit_pool_stats() end
    }
  end

  def callback_docs do
    """
    ### sandbox_info()
    Returns basic sandbox info: id, status, restart_count, created_at, resource_usage.

    ### sandbox_resource_usage()
    Returns memory/process usage: memory_bytes, processes, message_queue, uptime_ms.

    ### snakepit_session_stats()
    Returns Snakepit session stats: current_sessions, memory_usage_bytes.
    When stats are unavailable, current_sessions is nil and error is set.

    ### snakepit_pool_stats()
    Returns pool stats: workers, available, busy, queued, requests, errors,
    queue_timeouts, pool_saturated. When stats are unavailable, error is set.
    """
  end

  defp snapshot_for(sandbox_id) do
    usage = sandbox_resource_usage_for(sandbox_id)
    stats = snakepit_session_stats_for(sandbox_id)
    pool_stats = snakepit_pool_stats_for(sandbox_id)

    if error_map?(usage) and error_map?(stats) do
      snapshot_error(usage, stats, pool_stats)
    else
      %{
        sandbox_id: sandbox_id,
        sandbox: usage,
        snakepit: Map.put(stats, :pool, pool_stats)
      }
    end
  end

  defp sandbox_info do
    with_sandbox_id(&sandbox_info_for/1)
  end

  defp sandbox_resource_usage do
    with_sandbox_id(&sandbox_resource_usage_for/1)
  end

  defp snakepit_session_stats do
    with_sandbox_id(&snakepit_session_stats_for/1)
  end

  defp snakepit_pool_stats do
    with_sandbox_id(&snakepit_pool_stats_for/1)
  end

  defp with_sandbox_id(fun) do
    case SnakepitSandboxDemo.Store.get_sandbox_id() do
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

  defp snakepit_session_stats_for(sandbox_id) do
    with {:ok, session_store} <-
           SnakepitSandboxDemo.SandboxModules.resolve_module(
             sandbox_id,
             Snakepit.Bridge.SessionStore
           ),
         {:ok, pid} <- ensure_session_store_pid(sandbox_id, session_store),
         true <- is_pid(pid),
         {:ok, stats} <- Sandbox.run(sandbox_id, fn -> apply(session_store, :get_stats, []) end) do
      %{
        current_sessions: Map.get(stats, :current_sessions),
        memory_usage_bytes: Map.get(stats, :memory_usage_bytes)
      }
    else
      {:ok, nil} -> snakepit_stats_error("session_store_not_running")
      false -> snakepit_stats_error("session_store_not_running")
      {:error, reason} -> snakepit_stats_error(format_reason(reason))
    end
  end

  defp snakepit_pool_stats_for(sandbox_id) do
    with {:ok, pool_module} <-
           SnakepitSandboxDemo.SandboxModules.resolve_module(
             sandbox_id,
             Snakepit.Pool
           ),
         {:ok, pid} <- Sandbox.run(sandbox_id, fn -> Process.whereis(pool_module) end),
         true <- is_pid(pid),
         {:ok, stats} <- Sandbox.run(sandbox_id, fn -> apply(pool_module, :get_stats, []) end) do
      %{
        workers: Map.get(stats, :workers),
        available: Map.get(stats, :available),
        busy: Map.get(stats, :busy),
        queued: Map.get(stats, :queued),
        requests: Map.get(stats, :requests),
        errors: Map.get(stats, :errors),
        queue_timeouts: Map.get(stats, :queue_timeouts),
        pool_saturated: Map.get(stats, :pool_saturated)
      }
    else
      {:ok, nil} -> snakepit_pool_error("pool_not_running")
      false -> snakepit_pool_error("pool_not_running")
      {:error, reason} -> snakepit_pool_error(format_reason(reason))
    end
  end

  defp ensure_session_store_pid(sandbox_id, session_store) do
    case Sandbox.run(sandbox_id, fn -> ensure_session_store_started(session_store) end) do
      {:ok, pid} when is_pid(pid) ->
        {:ok, pid}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:ok, other} ->
        {:error, {:session_store_unavailable, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_session_store_started(session_store) do
    case Process.whereis(session_store) do
      pid when is_pid(pid) ->
        pid

      _ ->
        case apply(session_store, :start_link, [[name: session_store]]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
          other -> {:error, other}
        end
    end
  end

  defp snakepit_stats_error(reason) do
    %{
      current_sessions: nil,
      memory_usage_bytes: nil,
      error: reason
    }
  end

  defp snakepit_pool_error(reason) do
    %{
      error: reason,
      workers: nil,
      available: nil,
      busy: nil,
      queued: nil,
      requests: nil,
      errors: nil,
      queue_timeouts: nil,
      pool_saturated: nil
    }
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

  defp error_map?(value) when is_map(value), do: Map.has_key?(value, :error)
  defp error_map?(_), do: true

  defp snapshot_error(usage, stats, pool_stats) do
    pool_error = Map.get(pool_stats, :error)

    %{
      error:
        "snapshot_unavailable sandbox=#{Map.get(usage, :error)} snakepit=#{Map.get(stats, :error)} pool=#{pool_error}"
    }
  end

  defp format_reason(reason) do
    reason
    |> inspect()
    |> String.replace("\n", " ")
  end
end
