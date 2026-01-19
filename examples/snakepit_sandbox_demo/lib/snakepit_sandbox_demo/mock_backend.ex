defmodule SnakepitSandboxDemo.MockBackend do
  @moduledoc false

  @behaviour Puck.Backend

  alias Beamlens.Operator.Tools
  alias Puck.Message
  alias Puck.Response

  @impl true
  def call(%{queue: queue} = config, messages, _opts) do
    response =
      queue
      |> next_response(Map.get(config, :default_response))
      |> hydrate_latest_snapshot(messages)

    {:ok,
     Response.new(
       content: response,
       finish_reason: :stop,
       usage: %{input_tokens: 0, output_tokens: 0},
       metadata: %{provider: "mock", model: "mock-queue"}
     )}
  end

  @impl true
  def stream(config, _messages, _opts) do
    with {:ok, response} <- call(config, [], []) do
      stream =
        Stream.map([response.content], fn content ->
          %{type: :content, content: content, metadata: %{partial: false, backend: :mock_queue}}
        end)

      {:ok, stream}
    end
  end

  @impl true
  def introspect(_config) do
    %{
      provider: "mock",
      model: "mock-queue",
      operation: :chat,
      capabilities: [:deterministic]
    }
  end

  defp next_response(queue, default_response) do
    Agent.get_and_update(queue, fn
      [next | rest] -> {next, rest}
      [] -> {default_response, []}
    end)
  end

  defp hydrate_latest_snapshot(
         %Tools.SendNotification{snapshot_ids: ["latest"]} = response,
         messages
       ) do
    case latest_snapshot_id(messages) do
      nil -> response
      snapshot_id -> %{response | snapshot_ids: [snapshot_id]}
    end
  end

  defp hydrate_latest_snapshot(response, _messages), do: response

  defp latest_snapshot_id(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(&snapshot_id_from_message/1)
  end

  defp latest_snapshot_id(_messages), do: nil

  defp snapshot_id_from_message(%Message{content: content}) do
    snapshot_id_from_content(content)
  end

  defp snapshot_id_from_message(%{content: content}) do
    snapshot_id_from_content(content)
  end

  defp snapshot_id_from_message(_message), do: nil

  defp snapshot_id_from_content(content) do
    case normalize_content(content) do
      nil ->
        nil

      text ->
        case Jason.decode(text) do
          {:ok, %{"id" => id, "captured_at" => _}} -> id
          _ -> nil
        end
    end
  end

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    content
    |> Enum.map(&extract_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp normalize_content(_content), do: nil

  defp extract_text(%{type: :text, text: text}) when is_binary(text), do: text
  defp extract_text(%{type: "text", text: text}) when is_binary(text), do: text
  defp extract_text(_), do: ""
end
