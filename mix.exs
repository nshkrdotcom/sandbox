defmodule Sandbox.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      elixirc_paths: elixirc_paths(Mix.env()),
      # Suppress module redefinition warnings during tests (expected behavior for sandbox isolation)
      elixirc_options: elixirc_options(Mix.env()),
      aliases: aliases(),
      dialyzer: dialyzer()
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
      {:supertester, "0.5.1", only: :test},
      {:cluster_test, github: "nshkrdotcom/cluster_test", only: [:dev, :test]},

      # Documentation
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},

      # Code analysis
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Testing
      {:stream_data, "~> 1.0"},

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
      description: description(),
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Online documentation" => "https://hexdocs.pm/sandbox",
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["NSHKr <ZeroTrust@NSHkr.com>"],
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md assets guides),
      exclude_patterns: [
        "priv/plts",
        ".DS_Store"
      ]
    ]
  end

  defp docs do
    [
      main: "overview",
      name: "Sandbox",
      source_ref: "v#{@version}",
      source_url: @source_url,
      homepage_url: @source_url,
      assets: %{"assets" => "assets"},
      logo: "assets/sandbox.svg",
      extras: [
        {"README.md", [title: "Overview", filename: "overview"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        # Guides
        {"guides/getting_started.md", [title: "Getting Started"]},
        {"guides/hot_reload.md", [title: "Hot Reload"]},
        {"guides/module_transformation.md", [title: "Module Transformation"]},
        {"guides/compilation.md", [title: "Compilation"]},
        {"guides/configuration.md", [title: "Configuration"]},
        {"guides/architecture.md", [title: "Architecture"]},
        {"guides/evolution_substrate.md", [title: "Evolution Substrate"]},
        # Examples
        {"examples/README.md", [title: "Examples Overview", filename: "examples"]},
        {"examples/beamlens_sandbox_demo/README.md",
         [title: "Beamlens Demo", filename: "beamlens_demo"]}
      ],
      groups_for_extras: [
        Introduction: [
          "README.md",
          "guides/getting_started.md"
        ],
        Guides: [
          "guides/hot_reload.md",
          "guides/module_transformation.md",
          "guides/compilation.md",
          "guides/configuration.md"
        ],
        Architecture: [
          "guides/architecture.md",
          "guides/evolution_substrate.md"
        ],
        Examples: [
          "examples/README.md",
          "examples/beamlens_sandbox_demo/README.md"
        ],
        About: [
          "CHANGELOG.md"
        ]
      ],
      before_closing_head_tag: &docs_before_closing_head_tag/1,
      groups_for_modules: [
        Core: [
          Sandbox,
          Sandbox.Application,
          Sandbox.Manager,
          Sandbox.IsolatedCompiler,
          Sandbox.ModuleVersionManager
        ],
        Isolation: [
          Sandbox.ProcessIsolator,
          Sandbox.ModuleTransformer,
          Sandbox.VirtualCodeTable
        ],
        "Safety & Monitoring": [
          Sandbox.ResourceMonitor,
          Sandbox.SecurityController,
          Sandbox.StatePreservation
        ],
        Infrastructure: [
          Sandbox.FileWatcher,
          Sandbox.Config,
          Sandbox.InProcessCompiler
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

  defp docs_before_closing_head_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
    <script>
      let initialized = false;

      window.addEventListener("exdoc:loaded", () => {
        if (!initialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          initialized = true;
        }

        let id = 0;
        for (const codeEl of document.querySelectorAll("pre code.mermaid")) {
          const preEl = codeEl.parentElement;
          const graphDefinition = codeEl.textContent;
          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + id++;
          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          });
        }
      });
    </script>
    """
  end

  defp docs_before_closing_head_tag(_), do: ""

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Suppress module redefinition warnings during tests - they're expected for sandbox isolation
  defp elixirc_options(:test), do: [ignore_module_conflict: true]
  defp elixirc_options(_), do: []

  defp aliases do
    [
      "test.examples": ["cmd --cd examples/beamlens_sandbox_demo mix test"]
    ]
  end

  def dialyzer do
    [
      plt_add_apps: [:ex_unit]
    ]
  end
end
