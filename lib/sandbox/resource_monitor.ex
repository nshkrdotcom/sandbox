defmodule Sandbox.ResourceMonitor do
  @moduledoc """
  Monitors and enforces resource limits for sandboxes.

  This module will be implemented in a later task to provide:
  - Real-time resource usage tracking
  - Limit enforcement and alerting
  - Performance metrics collection
  - Resource cleanup coordination
  - Security violation detection
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.debug("ResourceMonitor starting with opts: #{inspect(opts)}")
    {:ok, %{}}
  end

  @impl true
  def handle_call(_request, _from, state) do
    {:reply, :not_implemented, state}
  end

  @impl true
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_info, state) do
    {:noreply, state}
  end
end
