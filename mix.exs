defmodule Sandbox.MixProject do
  use Mix.Project

  @version "0.0.1"
  @source_url "https://github.com/nshkrdotcom/sandbox"

  def project do
    [
      app: :sandbox,
      version: @version,
      elixir: "~> 1.18",
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
      extra_applications: [:logger, :crypto, :file_system],
      mod: {Sandbox.Application, []}
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:file_system, "~> 1.0"},

      # Testing infrastructure
      {:supertester, path: "../supertester"},
      {:cluster_test, path: "../cluster_test", only: [:dev, :test]},

      # Documentation
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},

      # Code analysis
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # Testing
      {:stream_data, "~> 1.0", only: [:dev, :test]},

      # Telemetry and monitoring
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},

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
        Core: [
          Sandbox,
          Sandbox.Application,
          Sandbox.Manager,
          Sandbox.IsolatedCompiler,
          Sandbox.ModuleVersionManager
        ],
        Components: [
          Sandbox.ResourceMonitor,
          Sandbox.SecurityController,
          Sandbox.FileWatcher,
          Sandbox.StatePreservation
        ],
        Models: [
          Sandbox.Models.SandboxState,
          Sandbox.Models.ModuleVersion,
          Sandbox.Models.CompilationResult
        ],
        Testing: [
          Sandbox.Test.Helpers
        ]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
