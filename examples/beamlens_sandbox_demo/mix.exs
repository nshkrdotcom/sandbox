defmodule BeamlensSandboxDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamlens_sandbox_demo,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Demo.Application, []}
    ]
  end

  defp elixirc_paths(_env), do: ["lib", "sandbox_app/lib"]

  defp deps do
    [
      {:sandbox, path: "../../"},
      {:beamlens,
       github: "nshkrdotcom/beamlens", ref: "3684b91f4ea4466f53ddf820aae8aebd5cb262f3"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
