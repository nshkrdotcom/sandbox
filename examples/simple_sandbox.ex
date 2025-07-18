defmodule SimpleSandbox.Supervisor do
  @moduledoc """
  Example supervisor for demonstrating Sandbox capabilities.
  
  This supervisor starts a simple counter GenServer that can be
  hot-reloaded to demonstrate version management.
  """
  
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {SimpleSandbox.Counter, name: counter_name(opts)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp counter_name(opts) do
    case opts[:unique_id] do
      nil -> SimpleSandbox.Counter
      id -> :"SimpleSandbox.Counter.#{id}"
    end
  end
end

defmodule SimpleSandbox.Counter do
  @moduledoc """
  A simple counter GenServer that maintains state.
  
  This is useful for demonstrating hot-reload with state preservation.
  """
  
  use GenServer

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, 0, opts)
  end

  def increment(server) do
    GenServer.call(server, :increment)
  end

  def get_count(server) do
    GenServer.call(server, :get_count)
  end

  def reset(server) do
    GenServer.cast(server, :reset)
  end

  # Server Callbacks

  @impl true
  def init(initial_count) do
    {:ok, %{count: initial_count, version: 1}}
  end

  @impl true
  def handle_call(:increment, _from, %{count: count} = state) do
    new_count = count + 1
    {:reply, new_count, %{state | count: new_count}}
  end

  @impl true
  def handle_call(:get_count, _from, %{count: count} = state) do
    {:reply, count, state}
  end

  @impl true
  def handle_cast(:reset, state) do
    {:noreply, %{state | count: 0}}
  end

  # Hot-reload support
  @impl true
  def code_change(_old_vsn, state, _extra) do
    # This is called during hot-reload
    # You can migrate state here if needed
    {:ok, Map.put(state, :upgraded_at, System.system_time(:second))}
  end
end