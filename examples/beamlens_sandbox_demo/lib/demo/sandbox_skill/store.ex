defmodule Demo.SandboxSkill.Store do
  @moduledoc "GenServer store for the sandbox id used by demo skills."

  use GenServer

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{sandbox_id: nil}, name: name)
  end

  def set_sandbox_id(sandbox_id) when is_binary(sandbox_id) do
    call_store({:set_sandbox_id, sandbox_id})
  end

  def get_sandbox_id do
    call_store(:get_sandbox_id)
  end

  def clear do
    call_store(:clear)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:get_sandbox_id, _from, state) do
    {:reply, {:ok, state.sandbox_id}, state}
  end

  def handle_call({:set_sandbox_id, sandbox_id}, _from, state) do
    {:reply, :ok, %{state | sandbox_id: sandbox_id}}
  end

  def handle_call(:clear, _from, state) do
    {:reply, :ok, %{state | sandbox_id: nil}}
  end

  defp call_store(message) do
    case GenServer.whereis(__MODULE__) do
      nil -> {:error, :store_not_running}
      pid -> GenServer.call(pid, message)
    end
  end
end
