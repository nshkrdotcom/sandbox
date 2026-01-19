defmodule SnakepitSandboxDemo.Store do
  @moduledoc "Stores demo state (sandbox id and snakepit supervisor pid)."

  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def set_sandbox_id(sandbox_id) when is_binary(sandbox_id) do
    GenServer.call(__MODULE__, {:set_sandbox_id, sandbox_id})
  end

  def get_sandbox_id do
    GenServer.call(__MODULE__, :get_sandbox_id)
  end

  def set_snakepit_pid(pid) when is_pid(pid) do
    GenServer.call(__MODULE__, {:set_snakepit_pid, pid})
  end

  def get_snakepit_pid do
    GenServer.call(__MODULE__, :get_snakepit_pid)
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_state) do
    {:ok, %{sandbox_id: nil, snakepit_pid: nil}}
  end

  @impl true
  def handle_call({:set_sandbox_id, sandbox_id}, _from, state) do
    {:reply, :ok, %{state | sandbox_id: sandbox_id}}
  end

  def handle_call(:get_sandbox_id, _from, state) do
    {:reply, {:ok, state.sandbox_id}, state}
  end

  def handle_call({:set_snakepit_pid, pid}, _from, state) do
    {:reply, :ok, %{state | snakepit_pid: pid}}
  end

  def handle_call(:get_snakepit_pid, _from, state) do
    {:reply, {:ok, state.snakepit_pid}, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{sandbox_id: nil, snakepit_pid: nil}}
  end
end
