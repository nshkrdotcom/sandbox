defmodule SnakepitSandboxDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :snakepit_sandbox_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {SnakepitSandboxDemo.Application, []}
    ]
  end

  defp deps do
    [
      {:sandbox, path: "../../"},
      {:beamlens, github: "beamlens/beamlens"},
      {:snakepit,
       github: "nshkrdotcom/snakepit",
       ref: "35da013bb2647e43c8232b94b42051aecd17302b",
       runtime: false},
      {:req, "~> 0.5"}
    ]
  end
end
