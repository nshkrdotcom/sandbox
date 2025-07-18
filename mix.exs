defmodule Sandbox.MixProject do
  use Mix.Project

  @version "0.0.1"
  @source_url "https://github.com/nshkrdotcom/sandbox"

  def project do
    [
      app: :sandbox,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url,
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto],
      mod: {Sandbox, []}
    ]
  end

  defp deps do
    [
      # Documentation
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      
      # Code analysis
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      
      # Testing
      {:stream_data, "~> 1.0", only: [:dev, :test]},
      
      # Optional dependencies
      {:jason, "~> 1.4", optional: true}
    ]
  end

  defp description do
    """
    Isolated OTP application management with hot-reload capabilities.
    
    Sandbox enables you to create, manage, and hot-reload isolated OTP
    applications within your Elixir system. Perfect for plugin systems,
    learning environments, and safe code execution.
    """
  end

  defp package do
    [
      name: "sandbox",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Docs" => "https://hexdocs.pm/sandbox"
      },
      maintainers: ["NSHKr <ZeroTrust@NSHkr.com>"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      name: "Sandbox",
      source_url: @source_url,
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Core": [
          Sandbox,
          Sandbox.Manager,
          Sandbox.IsolatedCompiler,
          Sandbox.ModuleVersionManager
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end