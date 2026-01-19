defmodule SnakepitSandboxDemo.SandboxSupervisor do
  @moduledoc "Minimal supervisor used to anchor the sandbox lifecycle."

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
