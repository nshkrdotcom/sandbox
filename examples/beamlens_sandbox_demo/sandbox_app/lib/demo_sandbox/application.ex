defmodule DemoSandbox.Application do
  @moduledoc "Sandboxed application for the demo."

  use Application

  def start(_type, _args) do
    children = [
      DemoSandbox.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: DemoSandbox.AppSupervisor)
  end
end
