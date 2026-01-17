defmodule DemoSandbox.Supervisor do
  @moduledoc "Supervisor for demo sandbox workers."

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    children = [
      {DemoSandbox.Worker, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
