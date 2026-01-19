# Snakepit Sandbox Demo

This demo runs the Snakepit supervision tree inside Sandbox and evaluates it with Beamlens.
Pooling is disabled so no external Python workers are required.

## Requirements
- Elixir 1.18+
- `mix deps.get` in `examples/snakepit_sandbox_demo`
- Optional: local Snakepit checkout via `SNAKEPIT_PATH` (defaults to `deps/snakepit`)

## Quick start (mock)
```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=mock mix run -e "SnakepitSandboxDemo.CLI.run()"
```

## Anomaly run (mock)
```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=mock mix run -e "SnakepitSandboxDemo.CLI.run_anomaly()"
```

## Real provider run (Gemini example)
```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=google-ai GOOGLE_API_KEY=... mix run -e "SnakepitSandboxDemo.CLI.run()"
BEAMLENS_DEMO_PROVIDER=google-ai GOOGLE_API_KEY=... mix run -e "SnakepitSandboxDemo.CLI.run_anomaly()"
```

## How it works
- Copies Snakepit sources (`mix.exs`, `lib`, `config`, `priv`) to a temp sandbox dir.
- Applies module transformation and compiles Snakepit in an isolated code path.
- Starts `Snakepit.Application` inside the sandbox and unlinks the supervisor so it
  stays alive across `Sandbox.run` tasks.
- Ensures `Snakepit.Bridge.SessionStore` is running before Beamlens queries stats.
- Captures pool stats (workers, queued, saturation) alongside session stats in snapshots.
- Runs Beamlens with a strict BAML prompt (no `think`, tool-only responses).
- Mock provider uses a local queue-based backend to emit deterministic tool actions.
- Uses session count to set `healthy` or emit a `session_spike` warning.

## BAML + provider details
- Strict prompt: `priv/baml_src/operator_no_think.baml`
- Local BAML client stub: `priv/baml_src/beamlens.baml`
- Live providers are configured via `client_registry` and must expose a `Default` client
  to match `client Default` in the BAML prompt.

## Implementation map
- CLI and provider registry: `lib/snakepit_sandbox_demo/cli.ex`
- Sandbox boot and teardown: `lib/snakepit_sandbox_demo/sandbox_runner.ex`
- Beamlens tool callbacks: `lib/snakepit_sandbox_demo/sandbox_skill.ex`
- BAML sources: `priv/baml_src/operator_no_think.baml`, `priv/baml_src/beamlens.baml`

## Configuration
Env vars:
- `BEAMLENS_DEMO_PROVIDER`: `mock`, `anthropic`, `openai`, `google-ai`, `gemini-ai`, `ollama`
- `BEAMLENS_DEMO_MODEL`: override model name for live providers
- `BEAMLENS_DEMO_STRICT_TOOLS=0`: use Beamlens default prompt (enables `think`)
- `SNAKEPIT_PATH`: path to a local Snakepit checkout (defaults to `deps/snakepit`)
- `SNAKEPIT_SANDBOX_LOG_LEVEL`: `debug|info|warn|error` (default `info`)
- `SANDBOX_DEBUG_CYCLES=1`: log circular dependency details during module version tracking

Optional CLI opts (passed to `run/1` or `run_anomaly/1`):
- `seed_sessions: 15` (override anomaly session count)
- `session_store_timeout_ms: 2000`
- `session_store_poll_ms: 50`
- `operator_timeout: 30000`
- `max_iterations: 4`

Provider auth:
- Set the API key env var required by your provider (example: `GOOGLE_API_KEY` for
  `google-ai`). Refer to your provider's docs for exact names.

Logging:
- Sandbox logs honor `SNAKEPIT_SANDBOX_LOG_LEVEL`.
- Beamlens operator traces appear as `[BAML INFO]` and show prompt/tool traffic.

## Troubleshooting
- `Client Default not found`: provider registry must include a `Default` client name.
- `session stats unavailable`: SessionStore should self-heal; set
  `SNAKEPIT_SANDBOX_LOG_LEVEL=debug` for more details.
- `pool stats unavailable`: pooling is disabled in the demo; pool stats may report
  `pool_not_running` while still allowing session-based decisions.
- No warning in anomaly mode: confirm `seed_sessions` is > 10.

## Expected output
Normal run:
`[beamlens] state=healthy summary="snakepit stable"`

Anomaly run:
`[beamlens] state=warning summary="session count elevated"`
