defmodule DemoSandbox.Worker do
  @moduledoc "Minimal worker for sandbox execution."

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ready, [])
  end

  def answer do
    41
  end

  @impl true
  def init(state) do
    {:ok, state}
  end
end
