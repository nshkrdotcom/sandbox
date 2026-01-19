# Snakepit Sandbox Demo

This demo runs the Snakepit supervision tree inside a Sandbox and monitors it with Beamlens.
It uses module transformation for Snakepit and starts the transformed application inside
Sandbox so you can exercise a complex tree without external Python workers.

## Requirements

- `mix deps.get` will fetch Snakepit as a pinned git dependency.
- Set `SNAKEPIT_PATH` if you want to use a local checkout instead.
- Elixir 1.18+

Default path resolution uses the example's deps directory:

```
deps/snakepit
```

## Run (mock provider)

```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=mock mix run -e "SnakepitSandboxDemo.CLI.run()"
```

## Run (anomaly mode)

```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=mock mix run -e "SnakepitSandboxDemo.CLI.run_anomaly()"
```

## Run (real provider)

Example (Gemini):

```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=google-ai GOOGLE_API_KEY=... mix run -e "SnakepitSandboxDemo.CLI.run_anomaly()"
```

## Notes

- The demo sets `:snakepit` to `pooling_enabled: false` to avoid spawning external workers.
- If you want to point at a different Snakepit checkout, set `SNAKEPIT_PATH`.
- Set `SNAKEPIT_SANDBOX_LOG_LEVEL=debug` to see sandbox debug output.
- Set `SANDBOX_DEBUG_CYCLES=1` to log circular dependency details during module version tracking.
- For real providers, set `BEAMLENS_DEMO_PROVIDER` and the corresponding API keys.
- The demo uses a strict operator prompt that omits the `think` tool by default.
  Set `BEAMLENS_DEMO_STRICT_TOOLS=0` to use the default Beamlens prompt instead.
