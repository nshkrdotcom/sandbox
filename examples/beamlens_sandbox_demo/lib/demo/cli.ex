defmodule Demo.CLI do
  @moduledoc "CLI entry point for the sandbox and beamlens demo."

  alias Beamlens.Operator.CompletionResult
  alias Demo.{SandboxRunner, SandboxSkill}

  def run do
    run([])
  end

  def run(opts) when is_list(opts) do
    sandbox_id = Keyword.get(opts, :sandbox_id, "demo-1")
    sandbox_path = Keyword.get(opts, :sandbox_path, SandboxRunner.sandbox_path())
    operator_runner = Keyword.get(opts, :operator_runner, &run_operator/2)
    operator_opts = build_operator_opts(opts)

    case SandboxRunner.create_sandbox(sandbox_id, sandbox_path) do
      {:ok, _info} ->
        log_demo("sandbox created: #{sandbox_id}")
        result = run_steps(sandbox_id, operator_runner, operator_opts)
        destroy_result = SandboxRunner.destroy_sandbox(sandbox_id)
        log_destroy(destroy_result)
        result

      {:error, reason} ->
        log_demo("sandbox create error: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  defp run_steps(sandbox_id, operator_runner, operator_opts) do
    with {:ok, :hot_reloaded} <- SandboxRunner.hot_reload(sandbox_id),
         :ok <- log_demo("hot reload: ok"),
         {:ok, run_result} <- SandboxRunner.run_in_sandbox(sandbox_id),
         :ok <- log_demo("run result: #{run_result}"),
         :ok <- SandboxSkill.configure(sandbox_id),
         {:ok, operator_summary} <- run_operator_and_log(operator_runner, operator_opts) do
      {:ok, %{run_result: run_result, operator: operator_summary}}
    else
      {:error, reason} ->
        log_demo("error: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  defp run_operator_and_log(operator_runner, operator_opts) do
    case operator_runner.(SandboxSkill, operator_opts) do
      {:ok, operator_summary} ->
        log_operator(operator_summary)
        {:ok, operator_summary}

      {:error, reason} ->
        log_beamlens_error(reason)
        {:error, reason}
    end
  end

  def run_operator(skill, opts) do
    client_registry = Keyword.get(opts, :client_registry, %{})
    context = Keyword.get(opts, :context, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_iterations = Keyword.get(opts, :max_iterations, 2)

    with {:ok, pid} <-
           Beamlens.Operator.start_link(
             skill: skill,
             context: context,
             client_registry: client_registry,
             max_iterations: max_iterations,
             notify_pid: self()
           ),
         {:ok, _notifications} <- await_operator(pid, timeout),
         {:ok, completion} <- fetch_completion(pid, skill, timeout) do
      {:ok, summarize_completion(completion)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_operator(pid, timeout) do
    result = Beamlens.Operator.await(pid, timeout)
    if Process.alive?(pid), do: Beamlens.Operator.stop(pid)
    result
  end

  defp fetch_completion(pid, skill, timeout) do
    receive do
      {:operator_complete, ^pid, ^skill, %CompletionResult{} = completion} ->
        {:ok, completion}
    after
      timeout ->
        {:error, :operator_timeout}
    end
  end

  defp summarize_completion(%CompletionResult{state: state, notifications: notifications}) do
    %{
      state: state,
      summary: summary_from_notifications(notifications),
      notifications: length(notifications)
    }
  end

  defp summary_from_notifications([]), do: "sandbox stable"

  defp summary_from_notifications([notification | _]) do
    notification
    |> Map.get(:summary)
    |> normalize_summary()
  end

  defp normalize_summary(summary) when is_binary(summary) do
    summary
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_summary(80)
  end

  defp normalize_summary(_), do: "sandbox stable"

  defp truncate_summary(summary, max) do
    if String.length(summary) > max do
      String.slice(summary, 0, max - 3) <> "..."
    else
      summary
    end
  end

  defp build_operator_opts(opts) do
    [
      context: Keyword.get(opts, :operator_context, %{reason: "sandbox health check"}),
      client_registry: Keyword.get(opts, :client_registry, %{}),
      timeout: Keyword.get(opts, :operator_timeout, 30_000),
      max_iterations: Keyword.get(opts, :operator_max_iterations, 2)
    ]
  end

  defp log_demo(message) do
    IO.puts("[demo] #{message}")
    :ok
  end

  defp log_destroy(:ok) do
    IO.puts("[demo] sandbox destroyed")
    :ok
  end

  defp log_destroy({:error, reason}) do
    log_demo("sandbox destroy error: #{format_reason(reason)}")
  end

  defp log_operator(%{state: state, summary: summary, notifications: count}) do
    IO.puts("[beamlens] state=#{state} summary=\"#{summary}\"")
    IO.puts("[beamlens] notifications=#{count}")
    :ok
  end

  defp log_beamlens_error(reason) do
    IO.puts("[beamlens] error=#{format_reason(reason)}")
    :ok
  end

  defp format_reason(reason) do
    reason
    |> inspect()
    |> String.replace("\n", " ")
  end
end
