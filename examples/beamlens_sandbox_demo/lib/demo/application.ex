defmodule Demo.Application do
  @moduledoc "Starts the sandbox and beamlens processes for the demo."

  use Application

  def start(_type, _args) do
    children = [
      {Beamlens, operators: [Demo.SandboxSkill]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
  end
end
