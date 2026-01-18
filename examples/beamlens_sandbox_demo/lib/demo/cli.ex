defmodule Demo.CLI do
  @moduledoc "CLI entry point for the sandbox and beamlens demo."

  alias Beamlens.Operator.CompletionResult
  alias Demo.{SandboxAnomalySkill, SandboxRunner, SandboxSkill}

  @anomaly_process_threshold 10

  def run do
    run([])
  end

  def run(opts) when is_list(opts) do
    run_mode(:plumbing, opts)
  end

  def run_anomaly do
    run_anomaly([])
  end

  def run_anomaly(opts) when is_list(opts) do
    run_mode(:anomaly, opts)
  end

  defp run_mode(mode, opts) do
    sandbox_id = Keyword.get(opts, :sandbox_id, "demo-1")
    sandbox_path = Keyword.get(opts, :sandbox_path, SandboxRunner.sandbox_path())
    operator_runner = Keyword.get(opts, :operator_runner, &run_operator/2)

    case build_operator_opts(opts, mode) do
      {:ok, operator_opts} ->
        case SandboxRunner.create_sandbox(sandbox_id, sandbox_path) do
          {:ok, _info} ->
            log_demo("sandbox created: #{sandbox_id}")
            result = run_steps(sandbox_id, operator_runner, operator_opts, mode, opts)
            destroy_result = SandboxRunner.destroy_sandbox(sandbox_id)
            log_destroy(destroy_result)
            result

          {:error, reason} ->
            log_demo("sandbox create error: #{format_reason(reason)}")
            {:error, reason}
        end

      {:error, reason} ->
        log_demo("operator config error: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  defp run_steps(sandbox_id, operator_runner, operator_opts, mode, opts) do
    skill = operator_skill_for(mode, opts)

    with {:ok, :hot_reloaded} <- SandboxRunner.hot_reload(sandbox_id),
         :ok <- log_demo("hot reload: ok"),
         {:ok, run_result} <- SandboxRunner.run_in_sandbox(sandbox_id),
         :ok <- log_demo("run result: #{run_result}"),
         {:ok, anomaly_context} <- maybe_induce_anomaly(mode, sandbox_id, opts),
         :ok <- set_sandbox_target(sandbox_id),
         :ok <- validate_skill_snapshot(skill),
         {:ok, operator_summary} <-
           run_operator_and_log(
             operator_runner,
             skill,
             merge_operator_context(operator_opts, anomaly_context)
           ),
         :ok <- validate_operator_outcome(mode, sandbox_id, operator_summary) do
      {:ok, %{run_result: run_result, operator: operator_summary}}
    else
      {:error, reason} ->
        log_demo("error: #{format_reason(reason)}")
        {:error, reason}
    end
  end

  defp maybe_induce_anomaly(:anomaly, sandbox_id, opts) do
    process_load = Keyword.get(opts, :process_load, 25)

    cond do
      is_integer(process_load) and process_load > 0 ->
        case SandboxRunner.induce_process_load(sandbox_id, process_load) do
          {:ok, started} ->
            log_demo("process load injected: #{started} extra workers")
            {:ok, build_anomaly_context(sandbox_id, started)}

          {:error, reason} ->
            log_demo("process load error: #{format_reason(reason)}")
            {:error, reason}
        end

      is_integer(process_load) ->
        log_demo("process load skipped (process_load=#{process_load})")
        {:ok, %{}}

      true ->
        {:error, :invalid_process_load}
    end
  end

  defp maybe_induce_anomaly(_mode, _sandbox_id, _opts), do: {:ok, %{}}

  defp build_anomaly_context(_sandbox_id, _started) do
    %{
      anomaly: %{
        type: "process_load"
      }
    }
  end

  defp run_operator_and_log(operator_runner, skill, operator_opts) do
    case operator_runner.(skill, operator_opts) do
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
    puck_client = Keyword.get(opts, :puck_client)
    context = Keyword.get(opts, :context, %{})
    timeout = Keyword.get(opts, :timeout, 30_000)
    max_iterations = Keyword.get(opts, :max_iterations, 2)

    with {:ok, pid} <-
           Beamlens.Operator.start_link(
             skill: skill,
             context: context,
             client_registry: client_registry,
             puck_client: puck_client,
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

  defp operator_skill_for(:anomaly, opts) do
    Keyword.get(opts, :operator_skill, SandboxAnomalySkill)
  end

  defp operator_skill_for(_mode, opts) do
    Keyword.get(opts, :operator_skill, SandboxSkill)
  end

  defp set_sandbox_target(sandbox_id) do
    case Demo.SandboxSkill.Store.set_sandbox_id(sandbox_id) do
      :ok -> :ok
      {:error, _} = error -> error
      other -> {:error, {:skill_store_failed, other}}
    end
  end

  defp validate_skill_snapshot(skill) do
    case Code.ensure_loaded(skill) do
      {:module, _} ->
        if function_exported?(skill, :snapshot, 0) do
          case skill.snapshot() do
            %{error: error} -> {:error, {:skill_snapshot_failed, error}}
            %{} -> :ok
            other -> {:error, {:skill_snapshot_failed, other}}
          end
        else
          {:error, {:skill_missing_snapshot, skill}}
        end

      {:error, reason} ->
        {:error, {:skill_not_loaded, {skill, reason}}}
    end
  end

  defp validate_operator_outcome(:anomaly, sandbox_id, operator_summary) do
    case Sandbox.resource_usage(sandbox_id) do
      {:ok, usage} ->
        processes = Map.get(usage, :current_processes)

        if is_integer(processes) do
          state = normalize_state(Map.get(operator_summary, :state))
          notifications = Map.get(operator_summary, :notifications, 0) || 0

          cond do
            processes > @anomaly_process_threshold and state != :warning ->
              {:error, {:anomaly_state_mismatch, processes, @anomaly_process_threshold, state}}

            processes > @anomaly_process_threshold and notifications < 1 ->
              {:error, {:anomaly_notification_missing, processes, @anomaly_process_threshold}}

            processes <= @anomaly_process_threshold and state != :healthy ->
              {:error, {:anomaly_state_mismatch, processes, @anomaly_process_threshold, state}}

            processes <= @anomaly_process_threshold and notifications > 0 ->
              {:error, {:anomaly_unexpected_notification, processes, @anomaly_process_threshold}}

            true ->
              :ok
          end
        else
          {:error, {:anomaly_usage_invalid, usage}}
        end

      {:error, reason} ->
        {:error, {:anomaly_usage_failed, reason}}
    end
  end

  defp validate_operator_outcome(_mode, _sandbox_id, _operator_summary), do: :ok

  defp normalize_state(state) when is_atom(state), do: state

  defp normalize_state(state) when is_binary(state) do
    case String.downcase(state) do
      "healthy" -> :healthy
      "observing" -> :observing
      "warning" -> :warning
      "critical" -> :critical
      _ -> :unknown
    end
  end

  defp normalize_state(_), do: :unknown

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

  defp build_operator_opts(opts, mode) do
    case resolve_client_context(opts, mode) do
      {:ok, %{client_registry: client_registry, puck_client: puck_client}} ->
        operator_opts = [
          context: operator_context_for(opts, mode),
          client_registry: client_registry,
          timeout: Keyword.get(opts, :operator_timeout, 30_000),
          max_iterations: operator_max_iterations_for(opts, mode)
        ]

        operator_opts = maybe_add_puck_client(operator_opts, puck_client)

        {:ok, operator_opts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp merge_operator_context(operator_opts, extra_context)
       when is_list(operator_opts) and is_map(extra_context) do
    if map_size(extra_context) == 0 do
      operator_opts
    else
      Keyword.update!(operator_opts, :context, fn context ->
        Map.merge(context, extra_context)
      end)
    end
  end

  defp operator_context_for(opts, :plumbing) do
    Keyword.get(opts, :operator_context, %{reason: "sandbox health check"})
  end

  defp operator_context_for(opts, :anomaly) do
    Keyword.get(opts, :operator_context, %{
      reason:
        "sandbox health check with intentional process spike. " <>
          "If processes > 10, take_snapshot, send_notification, set_state, then done."
    })
  end

  defp operator_max_iterations_for(opts, :anomaly) do
    Keyword.get(opts, :operator_max_iterations, 5)
  end

  defp operator_max_iterations_for(opts, _mode) do
    Keyword.get(opts, :operator_max_iterations, 4)
  end

  defp resolve_client_context(opts, mode) do
    puck_client = Keyword.get(opts, :puck_client)

    case Keyword.fetch(opts, :client_registry) do
      {:ok, registry} ->
        {:ok, %{client_registry: registry, puck_client: puck_client}}

      :error ->
        if puck_client do
          {:ok, %{client_registry: %{}, puck_client: puck_client}}
        else
          build_client_context_from_env(mode)
        end
    end
  end

  defp maybe_add_puck_client(opts, nil), do: opts
  defp maybe_add_puck_client(opts, puck_client), do: Keyword.put(opts, :puck_client, puck_client)

  defp build_client_context_from_env(mode) do
    provider =
      System.get_env("BEAMLENS_DEMO_PROVIDER") ||
        System.get_env("BEAMLENS_TEST_PROVIDER") ||
        "anthropic"

    provider = String.downcase(provider)

    model_override =
      System.get_env("BEAMLENS_DEMO_MODEL") ||
        System.get_env("BEAMLENS_TEST_MODEL")

    case provider do
      "anthropic" ->
        with {:ok, registry} <- build_anthropic_registry(model_override) do
          {:ok, %{client_registry: registry, puck_client: nil}}
        end

      "openai" ->
        with {:ok, registry} <- build_openai_registry(model_override) do
          {:ok, %{client_registry: registry, puck_client: nil}}
        end

      "google-ai" ->
        with {:ok, registry} <- build_google_ai_registry(model_override) do
          {:ok, %{client_registry: registry, puck_client: nil}}
        end

      "gemini-ai" ->
        with {:ok, registry} <- build_google_ai_registry(model_override) do
          {:ok, %{client_registry: registry, puck_client: nil}}
        end

      "ollama" ->
        with {:ok, registry} <- build_ollama_registry(model_override) do
          {:ok, %{client_registry: registry, puck_client: nil}}
        end

      "mock" ->
        {:ok, %{client_registry: %{}, puck_client: mock_puck_client_for(mode)}}

      _ ->
        {:error,
         "Unknown provider: #{provider}. Use anthropic, openai, google-ai, gemini-ai, ollama, or mock"}
    end
  end

  defp build_anthropic_registry(model_override) do
    case System.get_env("ANTHROPIC_API_KEY") do
      nil ->
        {:error,
         "ANTHROPIC_API_KEY not set. Set it or choose BEAMLENS_DEMO_PROVIDER=google-ai (gemini-ai), ollama, or mock"}

      _key ->
        model = model_override || "claude-haiku-4-5-20251001"

        {:ok,
         %{
           primary: "Anthropic",
           clients: [
             %{
               name: "Anthropic",
               provider: "anthropic",
               options: %{model: model}
             }
           ]
         }}
    end
  end

  defp build_openai_registry(model_override) do
    case System.get_env("OPENAI_API_KEY") do
      nil ->
        {:error, "OPENAI_API_KEY not set"}

      _key ->
        model = model_override || "gpt-4o-mini"

        {:ok,
         %{
           primary: "OpenAI",
           clients: [
             %{
               name: "OpenAI",
               provider: "openai",
               options: %{model: model}
             }
           ]
         }}
    end
  end

  defp build_google_ai_registry(model_override) do
    case System.get_env("GOOGLE_API_KEY") do
      nil ->
        {:error,
         "GOOGLE_API_KEY not set. Set it or use BEAMLENS_DEMO_PROVIDER=anthropic, ollama, or mock"}

      _key ->
        model = model_override || "gemini-flash-lite-latest"

        {:ok,
         %{
           primary: "Gemini",
           clients: [
             %{
               name: "Gemini",
               provider: "google-ai",
               options: %{model: model}
             }
           ]
         }}
    end
  end

  defp build_ollama_registry(model_override) do
    case check_ollama_available() do
      :ok ->
        model = model_override || "qwen3:4b"

        {:ok,
         %{
           primary: "Ollama",
           clients: [
             %{
               name: "Ollama",
               provider: "openai-generic",
               options: %{base_url: "http://localhost:11434/v1", model: model}
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Ollama not available: #{reason}. Start with: ollama serve"}
    end
  end

  defp mock_puck_client_for(:anomaly) do
    responses = [
      %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
      %Beamlens.Operator.Tools.SendNotification{
        intent: "send_notification",
        type: "process_spike",
        summary: "process count elevated",
        severity: :warning,
        snapshot_ids: ["latest"]
      },
      %Beamlens.Operator.Tools.SetState{
        intent: "set_state",
        state: :warning,
        reason: "process count above threshold"
      },
      %Beamlens.Operator.Tools.Done{intent: "done"}
    ]

    Beamlens.Testing.mock_client(
      responses,
      default: %Beamlens.Operator.Tools.Done{intent: "done"}
    )
  end

  defp mock_puck_client_for(_mode) do
    responses = [
      %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
      %Beamlens.Operator.Tools.SetState{
        intent: "set_state",
        state: :healthy,
        reason: "process count normal"
      },
      %Beamlens.Operator.Tools.Done{intent: "done"}
    ]

    Beamlens.Testing.mock_client(
      responses,
      default: %Beamlens.Operator.Tools.Done{intent: "done"}
    )
  end

  defp check_ollama_available do
    Application.ensure_all_started(:inets)
    url = ~c"http://localhost:11434/api/tags"

    case :httpc.request(:get, {url, []}, [timeout: 5000], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        :ok

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "Ollama returned status #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
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
