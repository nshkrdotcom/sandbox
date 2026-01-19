# Snakepit Sandbox Demo

This demo runs the Snakepit supervision tree inside Sandbox and evaluates it with Beamlens.
Mock/quick runs keep pooling disabled; the real demo path enables pooling to surface
pool pressure signals.

## Requirements
- Elixir 1.18+
- `mix deps.get` in `examples/snakepit_sandbox_demo`
- Optional: local Snakepit checkout via `SNAKEPIT_PATH` (defaults to `deps/snakepit`)
- Real demo (pooling enabled): Python available for Snakepit's gRPC worker adapter
  plus `uv` for auto-installing Snakepit's Python deps into `.snakepit_python`.
  If you prefer manual setup, run `mix snakepit.setup` in the Snakepit repo and set
  `SNAKEPIT_PYTHON` to the venv interpreter.

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

## Real demo run (live provider + pooling)
```
cd examples/snakepit_sandbox_demo
mix deps.get
BEAMLENS_DEMO_PROVIDER=google-ai GOOGLE_API_KEY=... mix run -e "SnakepitSandboxDemo.CLI.run_real()"
BEAMLENS_DEMO_PROVIDER=google-ai GOOGLE_API_KEY=... mix run -e "SnakepitSandboxDemo.CLI.run_real_anomaly()"
```

## How it works
- Copies Snakepit sources (`mix.exs`, `lib`, `config`, `priv`) to a temp sandbox dir.
- Applies module transformation and compiles Snakepit in an isolated code path.
- Starts `Snakepit.Application` inside the sandbox and unlinks the supervisor so it
  stays alive across `Sandbox.run` tasks.
- Ensures `Snakepit.Bridge.SessionStore` is running before Beamlens queries stats.
- When pooling is enabled, starts gRPC dependencies (`:grpc`, `:ranch`, `:cowboy`)
  before Snakepit boots to avoid missing `:ranch_sup`.
- Sets `:adapter_module` to the sandbox-transformed `Snakepit.Adapters.GRPCPython`
  so worker starters can resolve `adapter.get_port/0` correctly.
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
- `SNAKEPIT_PYTHON`: override Python executable for gRPC workers
- `SNAKEPIT_SANDBOX_LOG_LEVEL`: `debug|info|warn|error` (default `info`)
- `SANDBOX_DEBUG_CYCLES=1`: log circular dependency details during module version tracking

Optional CLI opts (passed to `run/1` or `run_anomaly/1`):
- `seed_sessions: 15` (override anomaly session count)
- `session_store_timeout_ms: 2000`
- `session_store_poll_ms: 50`
- `operator_timeout: 30000`
- `max_iterations: 4`
- `pooling_enabled: false` (override pooling; real runs default to `true`)
- `pool_size: 4` (override pool size when pooling is enabled)
- `adapter_module: Snakepit.Adapters.GRPCPython` (override adapter module)
- `auto_install_python_deps: true` (real runs default to `true`)
- `python_env_dir: "/abs/path"` (override the default `.snakepit_python` venv location)

Provider auth:
- Set the API key env var required by your provider (example: `GOOGLE_API_KEY` for
  `google-ai`). Refer to your provider's docs for exact names.

Logging:
- Sandbox logs honor `SNAKEPIT_SANDBOX_LOG_LEVEL`.
- Beamlens operator traces appear as `[BAML INFO]` and show prompt/tool traffic.

## Troubleshooting
- `Client Default not found`: provider registry must include a `Default` client name.
- `Real demo requires a live provider`: `run_real*` rejects `BEAMLENS_DEMO_PROVIDER=mock`.
- `session stats unavailable`: SessionStore should self-heal; set
  `SNAKEPIT_SANDBOX_LOG_LEVEL=debug` for more details.
- `pool stats unavailable`: pooling may be disabled or the pool failed to start.
  For real runs, confirm Python requirements and `pooling_enabled` is true.
- `nil.get_port` / `adapter_module_unresolved`: adapter module not configured.
  Pass `adapter_module:` or rerun with the default pooling path.
- `ModuleNotFoundError: No module named 'google'`: Snakepit Python deps missing.
  Install `uv` (for auto-install) or run `mix snakepit.setup` and set `SNAKEPIT_PYTHON`.
- No warning in anomaly mode: confirm `seed_sessions` is > 10.

## Expected output
Normal run:
`[beamlens] state=healthy summary="snakepit stable"`

Anomaly run:
`[beamlens] state=warning summary="session count elevated"`
