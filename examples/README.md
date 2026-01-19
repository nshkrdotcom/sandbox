# Sandbox Examples

This directory contains working examples demonstrating Sandbox capabilities, from simple isolated execution to advanced integration with AI-powered monitoring systems.

## Overview

The examples progress in complexity:

| Example | Complexity | Purpose |
|---------|------------|---------|
| `simple_sandbox.ex` | Basic | Core concepts: supervisors, GenServers, hot-reload |
| `plugin_example.ex` | Intermediate | Building a plugin system with lifecycle management |
| `beamlens_sandbox_demo/` | Advanced | Full application integrating Sandbox with Beamlens AI monitoring |
| `snakepit_sandbox_demo/` | Advanced | Runs Snakepit inside a Sandbox and monitors it with Beamlens |

Each example is designed to be studied in order, building on concepts from the previous one.

---

## Example 1: Simple Sandbox

**File:** `simple_sandbox.ex`

### What This Example Teaches

This is the foundational example that demonstrates the core Sandbox primitives:

1. **Supervision Tree Construction** - How to build an OTP-compliant supervisor that works within a sandbox
2. **GenServer State Management** - Maintaining state that survives hot-reloads
3. **Code Change Callbacks** - Using `code_change/3` to migrate state during upgrades

### Technical Deep Dive

#### The Supervisor Module

```elixir
defmodule SimpleSandbox.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @impl true
  def init(opts) do
    children = [
      {SimpleSandbox.Counter, name: counter_name(opts)}
    ]
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp counter_name(opts) do
    case opts[:unique_id] do
      nil -> SimpleSandbox.Counter
      id -> :"SimpleSandbox.Counter.#{id}"
    end
  end
end
```

**Key Design Decisions:**

1. **Dynamic Naming via `unique_id`**: When running multiple sandboxes concurrently, each needs unique process names. The `unique_id` option generates sandbox-specific names like `SimpleSandbox.Counter.sandbox_1`. Without this, you'd get `:already_started` errors.

2. **`:one_for_one` Strategy**: Each child is independent. If the Counter crashes, only the Counter restarts. This is appropriate because the Counter has no dependencies. In a more complex sandbox, you might use `:rest_for_one` if children depend on startup order.

3. **Name Passed Through `opts`**: The supervisor accepts its own name through `opts[:name]`, allowing the Sandbox system to name it according to its internal conventions.

#### The Counter GenServer

```elixir
defmodule SimpleSandbox.Counter do
  use GenServer

  # State structure: %{count: integer(), version: integer()}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, 0, opts)
  end

  @impl true
  def init(initial_count) do
    {:ok, %{count: initial_count, version: 1}}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, Map.put(state, :upgraded_at, System.system_time(:second))}
  end
end
```

**Why This Design Matters for Hot-Reload:**

1. **Versioned State**: The `version` field in state lets you track which code version produced the current state. This is critical for debugging production issues where you need to know "was this state created before or after the fix?"

2. **`code_change/3` Implementation**: When Sandbox hot-reloads this module, the BEAM calls `code_change/3` on running processes. Here, we add an `:upgraded_at` timestamp so you can verify the upgrade happened. In production, this is where you'd migrate state schemas.

3. **Map-Based State**: Using a map (`%{count: _, version: _}`) instead of a bare integer makes state evolution possible. You can add fields in `code_change/3` without breaking existing processes.

### Running the Example

```elixir
# Start the Sandbox application first
{:ok, _} = Application.ensure_all_started(:sandbox)

# Create a sandbox with the SimpleSandbox supervisor
{:ok, info} = Sandbox.create_sandbox("counter-demo", SimpleSandbox.Supervisor)

# The counter is now running inside the sandbox
# Find the process and use it
{:ok, pid} = Sandbox.get_sandbox_pid("counter-demo")

# The counter is a child of the supervisor - to interact:
# 1. Get the transformed module name (Sandbox prefixes all modules)
{:ok, context} = Sandbox.Manager.get_hot_reload_context("counter-demo")
prefix = context.module_namespace_prefix
counter_module = :"Elixir.#{prefix}_SimpleSandbox.Counter"

# 2. Call the module functions
counter_module.increment(counter_module)  # Returns 1
counter_module.get_count(counter_module)   # Returns 1

# Now let's hot-reload a new version
new_code = """
defmodule SimpleSandbox.Counter do
  use GenServer

  # ... same implementation but with a change ...

  def increment(server) do
    GenServer.call(server, :increment)
  end

  def handle_call(:increment, _from, %{count: count} = state) do
    new_count = count + 10  # Changed from +1 to +10!
    {:reply, new_count, %{state | count: new_count}}
  end

  # ... rest of implementation ...
end
"""

{:ok, :hot_reloaded} = Sandbox.hot_reload_source("counter-demo", new_code)

# Now increment adds 10 instead of 1, but the count is preserved!
counter_module.increment(counter_module)  # Returns 11 (1 + 10)
```

---

## Example 2: Plugin System

**File:** `plugin_example.ex`

### What This Example Teaches

Building a complete plugin system with:

1. **Plugin Discovery and Loading** - Scanning directories for plugin code
2. **Lifecycle Management** - Load, update, and unload plugins
3. **Version-Aware Updates** - Hot-reload with partial failure handling
4. **Safe Plugin Invocation** - Calling plugin code with error boundaries

### Technical Deep Dive

#### The Plugin Loading Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                      load_plugin(plugin_dir)                     │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Sandbox.compile_sandbox(plugin_dir)             │
│                                                                  │
│  1. Scans directory for .ex files                               │
│  2. Compiles to BEAM binaries                                   │
│  3. Returns compile_info with:                                  │
│     - beam_files: ["/path/to/Plugin.beam", ...]                │
│     - app_file: "/path/to/plugin.app"                          │
│     - output: compiler messages                                 │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                  extract_plugin_info(app_file)                   │
│                                                                  │
│  Reads the .app file to extract:                                │
│  - app: :my_plugin                                              │
│  - supervisor: MyPlugin.Supervisor                              │
│  - version: "1.0.0"                                             │
│  - description: "..."                                           │
└───────────────────────────────┬─────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Sandbox.create_sandbox(...)                  │
│                                                                  │
│  Creates isolated runtime with:                                 │
│  - sandbox_id: "plugin_my_plugin"                               │
│  - supervisor_module: MyPlugin.Supervisor                       │
│  - sandbox_path: "/path/to/plugin"                              │
└─────────────────────────────────────────────────────────────────┘
```

#### Why `sandbox_id` Uses a Prefix

```elixir
sandbox_id = "plugin_#{plugin_name}"
```

This convention serves multiple purposes:

1. **Namespace Collision Prevention**: If your main app has a "users" module and a plugin also has "users", the `plugin_` prefix ensures they don't collide in Sandbox's internal registries.

2. **Easy Filtering**: `list_plugins/0` filters by prefix to return only plugin sandboxes:
   ```elixir
   Sandbox.list_sandboxes()
   |> Enum.filter(fn s -> String.starts_with?(s.id, "plugin_") end)
   ```

3. **Operational Clarity**: When debugging, you can immediately tell if a sandbox is a plugin vs. some other use case.

#### Partial Update Handling

The `update_plugin/2` function demonstrates a critical pattern - handling partial failures:

```elixir
def update_plugin(plugin_id, new_plugin_dir) do
  case Sandbox.compile_sandbox(new_plugin_dir) do
    {:ok, compile_info} ->
      results =
        Enum.map(compile_info.beam_files, fn beam_file ->
          beam_data = File.read!(beam_file)
          case Sandbox.hot_reload(plugin_id, beam_data) do
            {:ok, :hot_reloaded} -> {:ok, module}
            error -> {:error, {module, error}}
          end
        end)

      case Enum.filter(results, &match?({:error, _}, &1)) do
        [] -> {:ok, :all_modules_updated}
        errors -> {:error, {:partial_update, errors}}
      end
    ...
  end
end
```

**Why Partial Updates Are Dangerous:**

Imagine a plugin with two modules: `MyPlugin.API` and `MyPlugin.Storage`. If `API` hot-reloads successfully but `Storage` fails, you have:

- `API` at version 2 (new code)
- `Storage` at version 1 (old code)

If version 2 of `API` expects version 2 of `Storage`, you have undefined behavior. The `{:error, {:partial_update, errors}}` return tells the caller "something went wrong, you need to decide what to do."

**Production Strategy:**

```elixir
case update_plugin(plugin_id, new_dir) do
  {:ok, :all_modules_updated} ->
    Logger.info("Plugin #{plugin_id} updated successfully")

  {:error, {:partial_update, errors}} ->
    Logger.error("Partial update failure, rolling back")
    # Option 1: Roll back to previous version
    rollback_plugin(plugin_id)
    # Option 2: Restart the sandbox entirely
    Sandbox.restart_sandbox(plugin_id)
end
```

#### Safe Plugin Invocation

```elixir
def call_plugin(plugin_id, module, function, args) do
  case Sandbox.get_sandbox_pid(plugin_id) do
    {:ok, _pid} ->
      try do
        apply(module, function, args)
      rescue
        error -> {:error, {:plugin_error, error}}
      end

    {:error, :not_found} ->
      {:error, :plugin_not_loaded}
  end
end
```

**Critical Design Notes:**

1. **Check Before Call**: We verify the sandbox exists before calling. This prevents confusing errors if the plugin crashed between checks.

2. **Rescue Boundary**: The `try/rescue` ensures plugin exceptions don't propagate to the caller. A misbehaving plugin can't crash your main application.

3. **Module Transformation Caveat**: The `module` argument must be the *transformed* module name (with Sandbox prefix), not the original. In production, you'd add a lookup:

```elixir
def call_plugin(plugin_id, original_module, function, args) do
  case resolve_transformed_module(plugin_id, original_module) do
    {:ok, transformed_module} ->
      # ... safe call with transformed_module
    {:error, :not_found} ->
      {:error, :module_not_in_plugin}
  end
end
```

### Example Plugin Structure

The file includes an example plugin showing the expected structure:

```
my_plugin/
├── lib/
│   ├── my_plugin/
│   │   ├── supervisor.ex      # ExamplePlugin.Supervisor
│   │   └── worker.ex          # ExamplePlugin.Worker
│   └── my_plugin.ex           # Optional: main module
├── mix.exs
└── README.md
```

The `ExamplePlugin.Worker` demonstrates a stateful GenServer that tracks `processed_count`. This pattern is common in plugins that need to report metrics or maintain caches.

---

## Example 3: Beamlens Integration

**Directory:** `beamlens_sandbox_demo/`

This is a complete OTP application demonstrating the integration of Sandbox with [Beamlens](https://github.com/nshkrdotcom/beamlens), an AI-powered BEAM monitoring system. It's the most sophisticated example and represents a realistic production architecture.

### What This Example Teaches

1. **Multi-Application Coordination** - Sandbox running inside a larger OTP application
2. **AI Operator Integration** - Using LLM-powered operators to monitor sandbox health
3. **Skill-Based Monitoring** - Exposing sandbox metrics through Beamlens skills
4. **End-to-End Testing** - Testing async, multi-component systems

### Architecture Overview

```
┌────────────────────────────────────────────────────────────────────────┐
│                        BeamlensSandboxDemo Application                  │
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │                          Demo.Supervisor                          │ │
│  │                                                                   │ │
│  │   ┌─────────────────┐      ┌─────────────────────────────────┐  │ │
│  │   │    Beamlens     │      │     Beamlens.Operator.Supervisor │  │ │
│  │   │                 │      │                                  │  │ │
│  │   │  Coordinator    │◄────►│   ┌─────────────────────────┐   │  │ │
│  │   │                 │      │   │   Demo.SandboxSkill     │   │  │ │
│  │   └─────────────────┘      │   │   (Beamlens Operator)   │   │  │ │
│  │                            │   └───────────┬─────────────┘   │  │ │
│  │                            └───────────────┼─────────────────┘  │ │
│  └────────────────────────────────────────────┼─────────────────────┘ │
│                                               │                        │
│                                               ▼                        │
│  ┌──────────────────────────────────────────────────────────────────┐ │
│  │                    Sandbox (Dynamically Created)                  │ │
│  │                                                                   │ │
│  │   sandbox_id: "demo-1"                                           │ │
│  │   ┌────────────────────────────────────────────────────────┐    │ │
│  │   │              DemoSandbox.Supervisor (transformed)       │    │ │
│  │   │                                                         │    │ │
│  │   │   ┌──────────────────────────────────────────────────┐ │    │ │
│  │   │   │        DemoSandbox.Worker (transformed)          │ │    │ │
│  │   │   │                                                  │ │    │ │
│  │   │   │  answer() -> 41 (before hot-reload)              │ │    │ │
│  │   │   │  answer() -> 42 (after hot-reload)               │ │    │ │
│  │   │   └──────────────────────────────────────────────────┘ │    │ │
│  │   └────────────────────────────────────────────────────────┘    │ │
│  └──────────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────────┘
```

### Detailed Documentation

For complete technical documentation of this example, see:

**[beamlens_sandbox_demo/README.md](beamlens_sandbox_demo/README.md)**

This covers:
- Project structure and file organization
- The Beamlens Skill implementation
- Hot-reload demonstration flow
- CLI usage and output
- Testing strategies
- Extending the example

---

## Running the Examples

### Prerequisites

```bash
# Clone the sandbox repository
git clone https://github.com/nshkrdotcom/sandbox.git
cd sandbox

# Fetch dependencies
mix deps.get

# Compile
mix compile
```

### Simple Examples (no additional setup)

```elixir
# Start IEx with the sandbox application
iex -S mix

# Load and run simple_sandbox.ex
c("examples/simple_sandbox.ex")

# Create a sandbox with the example supervisor
{:ok, _} = Sandbox.create_sandbox("demo", SimpleSandbox.Supervisor)

# Verify it's running
Sandbox.list_sandboxes()
# => [%{id: "demo", status: :running, ...}]
```

### Plugin Example

```elixir
# In IEx
c("examples/plugin_example.ex")

# The example includes inline modules, so they're now loaded
# In a real scenario, you'd have plugin code in a separate directory

# List plugins (none yet)
PluginExample.list_plugins()
# => []
```

### Beamlens Demo (requires additional setup)

```bash
# Navigate to the demo directory
cd examples/beamlens_sandbox_demo

# Fetch demo-specific dependencies
mix deps.get

# Run the demo CLI
mix run -e "Demo.CLI.run()"
```

Expected output:
```
[demo] sandbox created: demo-1
[demo] hot reload: ok
[demo] run result: 42
[beamlens] state=complete summary="sandbox stable"
[beamlens] notifications=0
[demo] sandbox destroyed
```

---

## Design Philosophy

These examples embody several design principles that we believe lead to robust Sandbox usage:

### 1. Explicit Over Implicit

Every example uses explicit module names, explicit sandbox IDs, and explicit error handling. There's no magic. When something fails, the error message tells you exactly what went wrong.

### 2. Composition Over Inheritance

The Beamlens example shows how Sandbox composes with other systems (Beamlens operators) without requiring modification to either. Sandbox doesn't know about Beamlens; Beamlens doesn't know about Sandbox internals. They communicate through well-defined interfaces.

### 3. Fail Fast, Recover Gracefully

The plugin example shows explicit partial-failure handling. The simple example shows how supervisors recover from crashes. We don't hide failures; we surface them and provide recovery paths.

### 4. Test What Matters

The `sandbox_runner_test.exs` file tests the integration points, not implementation details. It verifies that sandboxes can be created, hot-reloaded, and destroyed - the operations users actually care about.

---

## Common Patterns

### Pattern: Unique Sandbox IDs

```elixir
# Good: Include context in ID
sandbox_id = "plugin_#{plugin_name}_#{System.unique_integer([:positive])}"

# Good: User-scoped sandboxes
sandbox_id = "user_#{user_id}_session_#{session_id}"

# Bad: Generic IDs that might collide
sandbox_id = "sandbox_1"  # What if two users both create "sandbox_1"?
```

### Pattern: Graceful Shutdown

```elixir
def run_in_sandbox(sandbox_id, fun) do
  try do
    result = Sandbox.run(sandbox_id, fun, timeout: 5_000)
    {:ok, result}
  catch
    :exit, {:timeout, _} ->
      Logger.warn("Sandbox #{sandbox_id} timed out, destroying")
      Sandbox.destroy_sandbox(sandbox_id)
      {:error, :timeout}
  end
end
```

### Pattern: Module Resolution

```elixir
def resolve_module(sandbox_id, original_module) do
  case Sandbox.ModuleTransformer.lookup_module_mapping(sandbox_id, original_module) do
    {:ok, transformed} -> {:ok, transformed}
    :not_found ->
      # Fallback: construct from prefix
      {:ok, context} = Sandbox.Manager.get_hot_reload_context(sandbox_id)
      {:ok, :"Elixir.#{context.module_namespace_prefix}_#{original_module}"}
  end
end
```

---

## Troubleshooting

### "Module not found" after hot-reload

The module name changed due to transformation. Use `Sandbox.ModuleTransformer.lookup_module_mapping/2` to find the new name.

### Sandbox creation fails with `:already_started`

A sandbox with that ID already exists. Either destroy it first or use a unique ID:
```elixir
Sandbox.destroy_sandbox(existing_id)
# or
sandbox_id = "#{base_id}_#{System.unique_integer([:positive])}"
```

### Hot-reload doesn't seem to take effect

1. Verify the reload succeeded: `{:ok, :hot_reloaded} = Sandbox.hot_reload(...)`
2. Check you're calling the transformed module, not the original
3. For GenServers, implement `code_change/3` if state migration is needed

### Tests fail with async issues

Sandbox operations have side effects (process creation, ETS updates). Use `async: false` in test modules and proper cleanup in `on_exit` callbacks.

---

## Next Steps

After studying these examples, explore:

1. **[Hot Reload Guide](../guides/hot_reload.md)** - Deep dive into hot-reload mechanics
2. **[Architecture Guide](../guides/architecture.md)** - Understand Sandbox internals
3. **[Evolution Substrate Guide](../guides/evolution_substrate.md)** - Advanced patterns for genetic programming

---

## Contributing Examples

We welcome new examples! Good examples:

1. Solve a real problem (not just "hello world")
2. Include comprehensive comments explaining *why*, not just *what*
3. Have tests that verify the example works
4. Follow the patterns established in existing examples

Submit examples via pull request to the [sandbox repository](https://github.com/nshkrdotcom/sandbox).
