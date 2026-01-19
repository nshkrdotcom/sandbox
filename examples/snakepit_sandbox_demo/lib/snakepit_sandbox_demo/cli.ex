defmodule SnakepitSandboxDemo.CLI do
  @moduledoc "CLI entry point for the Snakepit sandbox demo."

  require Logger

  alias Beamlens.LLM.Utils
  alias Beamlens.Operator.CompletionResult
  alias Beamlens.Skill.Base, as: BaseSkill
  alias SnakepitSandboxDemo.{SandboxRunner, SandboxSkill, Store}

  @default_sandbox_id "snakepit-demo-1"
  @default_operator_timeout 30_000
  @default_operator_max_iterations 4
  @anomaly_operator_max_iterations 5

  @anomaly_session_load 15
  @log_level_map %{
    "debug" => :debug,
    "info" => :info,
    "warn" => :warning,
    "warning" => :warning,
    "error" => :error
  }

  def run do
    run([])
  end

  def run(opts) when is_list(opts) do
    run_mode(:normal, opts)
  end

  def run_anomaly do
    run_anomaly([])
  end

  def run_anomaly(opts) when is_list(opts) do
    run_mode(:anomaly, opts)
  end

  defp run_mode(mode, opts) do
    configure_logger()

    sandbox_id = Keyword.get(opts, :sandbox_id, @default_sandbox_id)
    sandbox_path = Keyword.get(opts, :sandbox_path, SandboxRunner.snakepit_path())
    operator_runner = Keyword.get(opts, :operator_runner, &run_operator/2)

    result =
      try do
        with {:ok, operator_opts} <- build_operator_opts(opts, mode),
             {:ok, _info} <- SandboxRunner.create_sandbox(sandbox_id, sandbox_path),
             :ok <- SandboxRunner.start_snakepit(sandbox_id, opts),
             {:ok, _created} <- maybe_seed_sessions(mode, sandbox_id, opts),
             :ok <- Store.set_sandbox_id(sandbox_id),
             :ok <- validate_skill_snapshot(SandboxSkill),
             {:ok, operator_summary} <-
               run_operator_and_log(operator_runner, SandboxSkill, operator_opts) do
          {:ok, operator_summary}
        else
          {:error, reason} ->
            log_demo("error: #{format_reason(reason)}")
            {:error, reason}
        end
      after
        SandboxRunner.stop_snakepit(sandbox_id)
        log_destroy(SandboxRunner.destroy_sandbox(sandbox_id))
        Store.clear()
      end

    result
  end

  defp configure_logger do
    level =
      System.get_env("SNAKEPIT_SANDBOX_LOG_LEVEL") ||
        System.get_env("LOG_LEVEL") ||
        "info"

    level =
      level
      |> String.downcase()
      |> then(&Map.get(@log_level_map, &1, :info))

    Logger.configure(level: level)
  end

  defp maybe_seed_sessions(:anomaly, sandbox_id, opts) do
    session_load = Keyword.get(opts, :seed_sessions, @anomaly_session_load)

    case SandboxRunner.seed_sessions(sandbox_id, session_load) do
      {:ok, created} ->
        log_demo("seeded #{created} sessions")
        {:ok, created}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_seed_sessions(_mode, _sandbox_id, opts) do
    session_load = Keyword.get(opts, :seed_sessions, 0)

    if is_integer(session_load) and session_load > 0 do
      {:error, :unexpected_session_seed}
    else
      {:ok, 0}
    end
  end

  def run_operator(skill, opts) do
    client_registry = Keyword.get(opts, :client_registry, %{})
    puck_client = Keyword.get(opts, :puck_client)
    context = Keyword.get(opts, :context, %{})
    timeout = Keyword.get(opts, :timeout, @default_operator_timeout)
    max_iterations = Keyword.get(opts, :max_iterations, @default_operator_max_iterations)

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

  defp summary_from_notifications([]), do: "snakepit stable"

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

  defp normalize_summary(_), do: "snakepit stable"

  defp truncate_summary(summary, max) do
    if String.length(summary) > max do
      String.slice(summary, 0, max - 3) <> "..."
    else
      summary
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

  defp build_operator_opts(opts, mode) do
    case resolve_client_context(opts, mode) do
      {:ok, %{client_registry: client_registry, puck_client: puck_client}} ->
        operator_opts = [
          context: operator_context_for(opts, mode),
          client_registry: client_registry,
          timeout: Keyword.get(opts, :operator_timeout, @default_operator_timeout),
          max_iterations: operator_max_iterations_for(opts, mode)
        ]

        operator_opts = maybe_add_puck_client(operator_opts, puck_client)

        {:ok, operator_opts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_puck_client(opts, nil), do: opts
  defp maybe_add_puck_client(opts, puck_client), do: Keyword.put(opts, :puck_client, puck_client)

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

  defp build_client_context_from_env(mode) do
    provider =
      System.get_env("BEAMLENS_DEMO_PROVIDER") ||
        System.get_env("BEAMLENS_TEST_PROVIDER") ||
        "mock"

    provider = String.downcase(provider)

    model_override =
      System.get_env("BEAMLENS_DEMO_MODEL") ||
        System.get_env("BEAMLENS_TEST_MODEL")

    case provider do
      "anthropic" ->
        with {:ok, registry} <- build_anthropic_registry(model_override) do
          live_client_context(registry)
        end

      "openai" ->
        with {:ok, registry} <- build_openai_registry(model_override) do
          live_client_context(registry)
        end

      "google-ai" ->
        with {:ok, registry} <- build_google_ai_registry(model_override) do
          live_client_context(registry)
        end

      "gemini-ai" ->
        with {:ok, registry} <- build_google_ai_registry(model_override) do
          live_client_context(registry)
        end

      "ollama" ->
        with {:ok, registry} <- build_ollama_registry(model_override) do
          live_client_context(registry)
        end

      "mock" ->
        {:ok, %{client_registry: %{}, puck_client: mock_puck_client_for(mode)}}

      _ ->
        {:error,
         "Unknown provider: #{provider}. Use anthropic, openai, google-ai, gemini-ai, ollama, or mock"}
    end
  end

  defp live_client_context(registry) do
    if strict_tools_enabled?() do
      {:ok,
       %{client_registry: registry, puck_client: build_strict_puck_client(SandboxSkill, registry)}}
    else
      {:ok, %{client_registry: registry, puck_client: nil}}
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
           primary: "Default",
           clients: [
             %{
               name: "Default",
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
           primary: "Default",
           clients: [
             %{
               name: "Default",
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
           primary: "Default",
           clients: [
             %{
               name: "Default",
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
           primary: "Default",
           clients: [
             %{
               name: "Default",
               provider: "openai-generic",
               options: %{
                 base_url: "http://localhost:11434/v1",
                 model: model
               }
             }
           ]
         }}

      {:error, reason} ->
        {:error, "Ollama not available: #{reason}"}
    end
  end

  defp operator_context_for(opts, :normal) do
    Keyword.get(opts, :operator_context, %{reason: "sandbox health check"})
  end

  defp operator_context_for(opts, :anomaly) do
    Keyword.get(opts, :operator_context, %{
      reason:
        "sandbox health check with seeded sessions. " <>
          "If current_sessions > 10, take_snapshot, send_notification, set_state, then done."
    })
  end

  defp operator_max_iterations_for(opts, mode) do
    case Keyword.get(opts, :max_iterations) || Keyword.get(opts, :operator_max_iterations) do
      value when is_integer(value) and value > 0 ->
        value

      _ ->
        default_operator_max_iterations(mode)
    end
  end

  defp default_operator_max_iterations(:anomaly), do: @anomaly_operator_max_iterations
  defp default_operator_max_iterations(_mode), do: @default_operator_max_iterations

  defp mock_puck_client_for(mode) do
    responses =
      case mode do
        :anomaly ->
          [
            %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
            %Beamlens.Operator.Tools.SendNotification{
              intent: "send_notification",
              type: "session_spike",
              severity: "warning",
              summary: "session count elevated",
              snapshot_ids: ["latest"]
            },
            %Beamlens.Operator.Tools.SetState{
              intent: "set_state",
              state: :warning,
              reason: "session count above threshold"
            },
            %Beamlens.Operator.Tools.Done{intent: "done"}
          ]

        _ ->
          [
            %Beamlens.Operator.Tools.TakeSnapshot{intent: "take_snapshot"},
            %Beamlens.Operator.Tools.SetState{
              intent: "set_state",
              state: :healthy,
              reason: "session count normal"
            },
            %Beamlens.Operator.Tools.Done{intent: "done"}
          ]
      end

    {:ok, queue} = Agent.start_link(fn -> responses end)

    backend_config = %{
      queue: queue,
      default_response: %Beamlens.Operator.Tools.Done{intent: "done"}
    }

    Puck.Client.new({SnakepitSandboxDemo.MockBackend, backend_config})
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

  defp strict_tools_enabled? do
    case System.get_env("BEAMLENS_DEMO_STRICT_TOOLS") do
      nil -> true
      value -> truthy_env?(value)
    end
  end

  defp truthy_env?(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> then(&(&1 in ["1", "true", "yes", "on"]))
  end

  defp truthy_env?(_), do: false

  defp build_strict_puck_client(skill, client_registry) do
    system_prompt = skill.system_prompt()
    callback_docs = skill.callback_docs() <> "\n" <> BaseSkill.callback_docs()

    backend_config =
      %{
        function: "OperatorRunNoThink",
        args_format: :auto,
        args: fn messages ->
          %{
            messages: Utils.format_messages_for_baml(messages),
            system_prompt: system_prompt,
            callback_docs: callback_docs
          }
        end,
        path: Application.app_dir(:snakepit_sandbox_demo, "priv/baml_src")
      }
      |> Utils.maybe_add_client_registry(client_registry)

    Puck.Client.new(
      {Puck.Backends.Baml, backend_config},
      hooks: Beamlens.Telemetry.Hooks,
      auto_compaction: strict_compaction_config()
    )
  end

  defp strict_compaction_config do
    {:summarize, max_tokens: 50_000, keep_last: 5, prompt: strict_compaction_prompt()}
  end

  defp strict_compaction_prompt do
    """
    Summarize this monitoring session, preserving:
    - What anomalies or concerns were detected
    - Current system state and trend direction
    - Snapshot IDs referenced (preserve exact IDs)
    - Key metric values that informed decisions
    - Any notifications sent and their reasons

    Be concise. This summary will be used to continue monitoring.
    """
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
