defmodule SnakepitSandboxDemo.Application do
  @moduledoc "Starts the sandbox and beamlens processes for the demo."

  use Application

  def start(_type, _args) do
    children = [
      SnakepitSandboxDemo.Store,
      {Beamlens, operators: [SnakepitSandboxDemo.SandboxSkill]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: SnakepitSandboxDemo.Supervisor)
  end
end
