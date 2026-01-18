# Hot Reload Guide

Hot reloading is one of the most powerful features of the Sandbox library, enabling you to update running code without stopping your application. This guide covers everything you need to know about hot reloading in Sandbox.

## Table of Contents

1. [What is Hot Reload and Why It Matters](#what-is-hot-reload-and-why-it-matters)
2. [Hot Reloading Compiled BEAM Binaries](#hot-reloading-compiled-beam-binaries)
3. [Hot Reloading from Source Code](#hot-reloading-from-source-code)
4. [Batch Hot Reload Operations](#batch-hot-reload-operations)
5. [Version Management and Rollback](#version-management-and-rollback)
6. [State Preservation During Hot Reload](#state-preservation-during-hot-reload)
7. [Best Practices and Common Pitfalls](#best-practices-and-common-pitfalls)
8. [Complete Working Examples](#complete-working-examples)

---

## What is Hot Reload and Why It Matters

Hot reloading (also known as hot code swapping) is the ability to update running code without stopping the application or losing state. This is a fundamental capability in Erlang/OTP systems that the Sandbox library exposes in a safe, managed way.

### Why Hot Reload Matters

- **Zero-Downtime Updates**: Deploy bug fixes and features without interrupting users
- **Rapid Development**: Test changes instantly without restarting your application
- **State Preservation**: Keep accumulated state (caches, connections, counters) across updates
- **Plugin Systems**: Update plugins dynamically without affecting the host application
- **Live Debugging**: Fix issues in production systems without service interruption

### How Sandbox Hot Reload Works

When you hot reload a module in a Sandbox:

1. The new BEAM bytecode is loaded into the VM
2. Running processes using the old code continue until they make a new function call
3. State can be optionally migrated using custom handlers
4. Module versions are tracked for potential rollback
5. Dependencies are automatically detected and can be cascaded

<svg viewBox="0 0 640 280" xmlns="http://www.w3.org/2000/svg" style="max-width: 640px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="hot-arrow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#3b82f6"/>
    </marker>
  </defs>

  <!-- Main container -->
  <rect x="0" y="0" width="640" height="280" rx="8" fill="#f8fafc" stroke="#e2e8f0" stroke-width="2"/>

  <!-- Title -->
  <rect x="0" y="0" width="640" height="36" rx="8" fill="#1e293b"/>
  <rect x="0" y="20" width="640" height="16" fill="#1e293b"/>
  <text x="320" y="24" text-anchor="middle" font-size="13" font-weight="600" fill="#fff">Hot Reload Flow</text>

  <!-- Step labels -->
  <text x="100" y="64" text-anchor="middle" font-size="10" font-weight="500" fill="#64748b">1. New Code</text>
  <text x="280" y="64" text-anchor="middle" font-size="10" font-weight="500" fill="#64748b">2. Load Binary</text>
  <text x="480" y="64" text-anchor="middle" font-size="10" font-weight="500" fill="#64748b">3. State Migration</text>

  <!-- Step 1: BEAM Data -->
  <rect x="48" y="80" width="104" height="56" rx="6" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="100" y="104" text-anchor="middle" font-size="11" font-weight="500" fill="#1e40af">BEAM</text>
  <text x="100" y="120" text-anchor="middle" font-size="11" font-weight="500" fill="#1e40af">Data</text>

  <!-- Arrow 1 to 2 -->
  <line x1="152" y1="108" x2="192" y2="108" stroke="#3b82f6" stroke-width="2" marker-end="url(#hot-arrow)"/>

  <!-- Step 2: VM Code Server -->
  <rect x="208" y="80" width="144" height="56" rx="6" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="280" y="104" text-anchor="middle" font-size="11" font-weight="500" fill="#1e40af">VM Code</text>
  <text x="280" y="120" text-anchor="middle" font-size="11" font-weight="500" fill="#1e40af">Server</text>

  <!-- Arrow 2 to 3 -->
  <line x1="352" y1="108" x2="392" y2="108" stroke="#3b82f6" stroke-width="2" marker-end="url(#hot-arrow)"/>

  <!-- Step 3: GenServer States -->
  <rect x="408" y="80" width="144" height="56" rx="6" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="480" y="104" text-anchor="middle" font-size="11" font-weight="500" fill="#1e40af">GenServer</text>
  <text x="480" y="120" text-anchor="middle" font-size="11" font-weight="500" fill="#1e40af">States</text>

  <!-- Arrow down from Step 3 -->
  <line x1="480" y1="136" x2="480" y2="168" stroke="#3b82f6" stroke-width="2" marker-end="url(#hot-arrow)"/>

  <!-- Step 4: Version Manager (left bottom) -->
  <text x="220" y="168" text-anchor="middle" font-size="10" font-weight="500" fill="#64748b">4. Version Tracked</text>
  <rect x="148" y="184" width="144" height="56" rx="6" fill="#f0fdf4" stroke="#10b981" stroke-width="1.5"/>
  <text x="220" y="208" text-anchor="middle" font-size="11" font-weight="500" fill="#047857">Version</text>
  <text x="220" y="224" text-anchor="middle" font-size="11" font-weight="500" fill="#047857">Manager</text>

  <!-- Step 5: Running with New Code -->
  <rect x="408" y="184" width="144" height="56" rx="6" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="480" y="204" text-anchor="middle" font-size="11" font-weight="500" fill="#b45309">Running</text>
  <text x="480" y="220" text-anchor="middle" font-size="11" font-weight="500" fill="#b45309">with New Code</text>
</svg>

---

## Hot Reloading Compiled BEAM Binaries

The most direct way to hot reload is with pre-compiled BEAM bytecode. This gives you full control over the compilation process.

### Basic BEAM Hot Reload

```elixir
# First, compile your module to BEAM format
{:ok, compile_info} = Sandbox.compile_file("/path/to/my_module.ex")

# Read the compiled BEAM data
beam_data = compile_info.beam_files
  |> hd()
  |> File.read!()

# Hot reload the module in your sandbox
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data)
```

### Hot Reload with State Handler

When reloading modules that implement GenServers, you can provide a state migration function:

```elixir
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data,
  state_handler: fn old_state, old_version, new_version ->
    # Transform state from old format to new format
    %{
      old_state
      | schema_version: new_version,
        migrated_at: DateTime.utc_now(),
        # Add new fields with defaults
        new_field: default_value()
    }
  end
)
```

### Hot Reload Options

The `Sandbox.hot_reload/3` function accepts the following options:

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:state_handler` | function | `nil` | `(old_state, old_version, new_version) -> new_state` |
| `:use_state_preservation` | boolean | `true` | Whether to use advanced state preservation |
| `:coordinate_dependencies` | boolean | `true` | Whether to reload dependent modules |
| `:suspend_timeout` | integer | `5000` | Timeout for suspending processes (ms) |

### Example: Hot Reloading a Counter GenServer

```elixir
defmodule Counter.V1 do
  use GenServer

  def start_link(initial) do
    GenServer.start_link(__MODULE__, initial, name: __MODULE__)
  end

  def init(initial), do: {:ok, %{count: initial}}

  def increment, do: GenServer.call(__MODULE__, :increment)
  def get_count, do: GenServer.call(__MODULE__, :get_count)

  def handle_call(:increment, _from, %{count: c} = state) do
    {:reply, c + 1, %{state | count: c + 1}}
  end

  def handle_call(:get_count, _from, %{count: c} = state) do
    {:reply, c, state}
  end
end
```

After creating a sandbox and running Counter.V1:

```elixir
# Sandbox is running Counter.V1 with count: 42
# Now we want to add a new feature: tracking increment history

# Compile Counter.V2 with history tracking
{:ok, compile_info} = Sandbox.compile_file("/path/to/counter_v2.ex")
beam_data = File.read!(hd(compile_info.beam_files))

# Hot reload with state migration
{:ok, :hot_reloaded} = Sandbox.hot_reload("counter-sandbox", beam_data,
  state_handler: fn old_state, _old_v, _new_v ->
    # Migrate to new state format with history
    %{
      count: old_state.count,
      history: [old_state.count],  # Initialize history with current count
      created_at: DateTime.utc_now()
    }
  end
)

# The counter continues with count: 42 and now tracks history!
```

---

## Hot Reloading from Source Code

For convenience, Sandbox can compile and hot reload source code in a single step using `hot_reload_source/3`.

### Basic Source Hot Reload

```elixir
source_code = """
defmodule MyModule do
  def hello, do: "Hello, Updated World!"
end
"""

{:ok, :hot_reloaded} = Sandbox.hot_reload_source("my-sandbox", source_code)
```

### Source Hot Reload with Options

```elixir
{:ok, :hot_reloaded} = Sandbox.hot_reload_source("my-sandbox", source_code,
  state_handler: fn old_state, old_version, new_version ->
    migrate_state(old_state, old_version, new_version)
  end
)
```

### Module Transformation

When hot reloading from source, modules are automatically transformed to be namespaced within the sandbox. This prevents conflicts with the host application:

```elixir
# Original source code
defmodule MyModule do
  def greet(name), do: "Hello, #{name}!"
end

# After transformation (internal representation)
defmodule Sandbox.MyNamespace.MyModule do
  def greet(name), do: "Hello, #{name}!"
end
```

The transformation is transparent - you reference modules by their original names within the sandbox.

### Multiple Modules in Source

You can define multiple modules in a single source string:

```elixir
source_code = """
defmodule Counter do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def init(opts), do: {:ok, %{count: Keyword.get(opts, :initial, 0)}}
  def increment, do: GenServer.call(__MODULE__, :increment)

  def handle_call(:increment, _from, %{count: c} = state) do
    {:reply, c + 1, %{state | count: c + 1}}
  end
end

defmodule CounterAPI do
  def increment_twice do
    Counter.increment()
    Counter.increment()
  end
end
"""

{:ok, :hot_reloaded} = Sandbox.hot_reload_source("my-sandbox", source_code)
```

---

## Batch Hot Reload Operations

When updating multiple sandboxes with the same code, use batch operations for efficiency.

### Batch Hot Reload

```elixir
sandbox_ids = ["sandbox-1", "sandbox-2", "sandbox-3", "sandbox-4"]

# Batch hot reload with BEAM data
results = Sandbox.batch_hot_reload(sandbox_ids, beam_data,
  max_concurrency: 4,
  batch_timeout: :infinity
)

# Results is a list of {sandbox_id, result} tuples
Enum.each(results, fn
  {id, {:ok, :hot_reloaded}} ->
    IO.puts("#{id}: Successfully reloaded")
  {id, {:error, reason}} ->
    IO.puts("#{id}: Failed - #{inspect(reason)}")
end)
```

### Batch Hot Reload from Source

```elixir
source_code = """
defmodule SharedModule do
  @version "2.0.0"
  def version, do: @version
end
"""

# Automatically detects source vs BEAM
results = Sandbox.batch_hot_reload(sandbox_ids, source_code)
```

### Batch Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:max_concurrency` | integer | `System.schedulers_online()` | Maximum parallel operations |
| `:batch_timeout` | integer or `:infinity` | `:infinity` | Overall batch timeout |
| `:state_handler` | function | `nil` | State migration function |

### Handling Batch Results

```elixir
results = Sandbox.batch_hot_reload(sandbox_ids, beam_data)

# Separate successes and failures
{successes, failures} = Enum.split_with(results, fn
  {_id, {:ok, _}} -> true
  {_id, {:error, _}} -> false
end)

IO.puts("Reloaded #{length(successes)} sandboxes successfully")
IO.puts("Failed to reload #{length(failures)} sandboxes")

# Handle failures
Enum.each(failures, fn {id, {:error, reason}} ->
  Logger.error("Failed to hot reload sandbox #{id}: #{inspect(reason)}")
  # Optionally retry or rollback
end)
```

---

## Version Management and Rollback

Sandbox tracks all module versions automatically, enabling safe rollback when issues occur.

### Checking Module Versions

```elixir
# Get current version number
{:ok, version} = Sandbox.get_module_version("my-sandbox", MyModule)
# => {:ok, 3}

# List all versions with details
versions = Sandbox.list_module_versions("my-sandbox", MyModule)
# => [
#   %{version: 3, loaded_at: ~U[2024-01-15 10:30:00Z], checksum: "abc123..."},
#   %{version: 2, loaded_at: ~U[2024-01-14 14:20:00Z], checksum: "def456..."},
#   %{version: 1, loaded_at: ~U[2024-01-13 09:00:00Z], checksum: "ghi789..."}
# ]

# Get version history with statistics
history = Sandbox.get_version_history("my-sandbox", MyModule)
# => %{
#   current_version: 3,
#   total_versions: 3,
#   versions: [...]
# }
```

### Rolling Back to a Previous Version

```elixir
# Rollback to version 2
{:ok, :rolled_back} = Sandbox.rollback_module("my-sandbox", MyModule, 2)

# Verify rollback
{:ok, version} = Sandbox.get_module_version("my-sandbox", MyModule)
# => {:ok, 2}
```

### Safe Deployment Pattern

```elixir
defmodule SafeDeployer do
  def deploy_with_rollback(sandbox_id, new_beam_data) do
    # Record current version for potential rollback
    {:ok, old_version} = Sandbox.get_module_version(sandbox_id, TargetModule)

    # Attempt hot reload
    case Sandbox.hot_reload(sandbox_id, new_beam_data) do
      {:ok, :hot_reloaded} ->
        # Verify the new version works
        case verify_deployment(sandbox_id) do
          :ok ->
            {:ok, :deployed}
          {:error, reason} ->
            # Rollback on verification failure
            Sandbox.rollback_module(sandbox_id, TargetModule, old_version)
            {:error, {:verification_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:hot_reload_failed, reason}}
    end
  end

  defp verify_deployment(sandbox_id) do
    # Run health checks, smoke tests, etc.
    Sandbox.run(sandbox_id, fn ->
      TargetModule.health_check()
    end)
  end
end
```

### Version Cleanup

The `ModuleVersionManager` automatically limits stored versions (default: 10 per module). Older versions are cleaned up automatically when the limit is exceeded:

```elixir
# The 11th version triggers cleanup of the oldest version
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", new_beam_data)
# Version 1 is automatically removed if there are now 11 versions
```

---

## State Preservation During Hot Reload

The `StatePreservation` module provides advanced state handling capabilities during hot reloads.

### How State Preservation Works

1. **State Capture**: Before loading new code, the state of all affected GenServers is captured
2. **Code Loading**: New BEAM bytecode is loaded into the VM
3. **State Migration**: Captured states are migrated using the provided handler (or default)
4. **State Restoration**: Migrated states are restored to the running processes

### Capture Module States

```elixir
# Capture states of all processes using a module
{:ok, captured_states} = Sandbox.StatePreservation.capture_module_states(MyModule,
  timeout: 5000,
  preserve_supervisor_specs: true
)

# Each captured state contains:
# %{
#   pid: #PID<0.123.0>,
#   module: MyModule,
#   state: %{count: 42, ...},
#   captured_at: ~U[2024-01-15 10:30:00Z],
#   process_info: %{...},
#   supervisor_info: %{supervisor_pid: #PID<0.100.0>, ...}
# }
```

### State Migration Functions

The state handler function receives three arguments:

```elixir
state_handler = fn old_state, old_version, new_version ->
  # old_state: The captured state before hot reload
  # old_version: The version number of the old module
  # new_version: The version number of the new module

  # Return the migrated state
  migrate(old_state, old_version, new_version)
end
```

### Migration Strategies

**Strategy 1: Add New Fields with Defaults**

```elixir
state_handler = fn old_state, _old_v, _new_v ->
  Map.merge(%{
    new_field_1: default_value(),
    new_field_2: []
  }, old_state)
end
```

**Strategy 2: Transform Existing Fields**

```elixir
state_handler = fn old_state, _old_v, _new_v ->
  %{old_state |
    # Transform a list to a map
    items: Map.new(old_state.items, &{&1.id, &1})
  }
end
```

**Strategy 3: Version-Specific Migration**

```elixir
state_handler = fn old_state, old_version, new_version ->
  old_state
  |> migrate_if_needed(old_version, 2, &add_timestamps/1)
  |> migrate_if_needed(old_version, 3, &normalize_names/1)
  |> migrate_if_needed(old_version, 4, &add_metadata/1)
end

defp migrate_if_needed(state, from_version, threshold, migrator) do
  if from_version < threshold, do: migrator.(state), else: state
end
```

### State Compatibility Validation

The library automatically validates state compatibility:

```elixir
# States are validated for:
# - Type compatibility (map vs map, tuple vs tuple)
# - Key presence (for maps)
# - Size matching (for tuples)

{:ok, :compatible} = Sandbox.StatePreservation.validate_state_compatibility(
  %{count: 42, name: "test"},
  %{count: 100, name: "updated", new_field: true}
)

{:error, {:missing_keys, [:count]}} = Sandbox.StatePreservation.validate_state_compatibility(
  %{count: 42, name: "test"},
  %{name: "updated"}  # Missing :count key
)
```

### Preserve and Restore Cycle

For complete state preservation during hot reload:

```elixir
{:ok, :completed} = Sandbox.StatePreservation.preserve_and_restore(
  MyModule,
  old_version,
  new_version,
  timeout: 30_000,
  validate_compatibility: true,
  migration_function: &my_migration/3,
  rollback_on_failure: true
)
```

---

## Best Practices and Common Pitfalls

### Best Practices

#### 1. Always Test State Migrations

```elixir
defmodule StateMigrationTest do
  use ExUnit.Case

  test "migration from v1 to v2 preserves count" do
    v1_state = %{count: 42}
    v2_state = my_migration(v1_state, 1, 2)

    assert v2_state.count == 42
    assert Map.has_key?(v2_state, :history)
  end

  test "migration handles edge cases" do
    assert my_migration(%{count: 0}, 1, 2).count == 0
    assert my_migration(%{count: nil}, 1, 2).count == 0  # Default on nil
  end
end
```

#### 2. Use Checksums to Avoid Redundant Reloads

The library automatically deduplicates based on BEAM checksums:

```elixir
# First hot reload
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data)

# Same code again - returns existing version (no reload needed)
{:ok, existing_version} = Sandbox.ModuleVersionManager.register_module_version(
  "my-sandbox", MyModule, beam_data
)
```

#### 3. Handle GenServer Callbacks Properly

Ensure your GenServer can handle both old and new message formats during transition:

```elixir
defmodule MyServer do
  use GenServer

  # Handle old format
  def handle_call({:get, key}, _from, state) when is_atom(key) do
    {:reply, Map.get(state, key), state}
  end

  # Handle new format
  def handle_call({:get, key, opts}, _from, state) when is_atom(key) do
    default = Keyword.get(opts, :default)
    {:reply, Map.get(state, key, default), state}
  end
end
```

#### 4. Log Version Transitions

```elixir
state_handler = fn old_state, old_version, new_version ->
  Logger.info("Migrating state from v#{old_version} to v#{new_version}",
    module: __MODULE__,
    state_keys: Map.keys(old_state)
  )

  migrate(old_state, old_version, new_version)
end
```

#### 5. Use Gradual Rollouts for Critical Updates

```elixir
def gradual_rollout(sandbox_ids, new_beam_data, batch_size \\ 5) do
  sandbox_ids
  |> Enum.chunk_every(batch_size)
  |> Enum.reduce_while(:ok, fn batch, :ok ->
    results = Sandbox.batch_hot_reload(batch, new_beam_data)

    if all_successful?(results) do
      # Wait and monitor before proceeding
      Process.sleep(5_000)
      {:cont, :ok}
    else
      # Stop rollout on failure
      {:halt, {:error, {:batch_failed, results}}}
    end
  end)
end
```

### Common Pitfalls

#### Pitfall 1: Forgetting to Handle State Migration

**Problem**: Hot reload succeeds but process state is incompatible with new code.

```elixir
# Old state: %{count: 42}
# New code expects: %{count: 42, history: []}

# Without migration, the process will crash when accessing state.history
```

**Solution**: Always provide a state handler for structural changes.

#### Pitfall 2: Circular Dependencies

**Problem**: Module A depends on B, and B depends on A.

```elixir
# This will fail during registration
{:error, {:circular_dependency, [ModuleA, ModuleB, ModuleA]}}
```

**Solution**: Refactor to break the cycle, or use the parallel reload feature.

#### Pitfall 3: Long-Running Calls During Hot Reload

**Problem**: A long-running GenServer call holds the old code reference.

**Solution**: Set appropriate timeouts and handle the transition period:

```elixir
# Use suspend_timeout option
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data,
  suspend_timeout: 10_000  # Wait up to 10s for calls to complete
)
```

#### Pitfall 4: Not Handling Rollback Scenarios

**Problem**: New code fails, but no rollback mechanism exists.

**Solution**: Always record versions and implement rollback handling:

```elixir
def safe_hot_reload(sandbox_id, new_beam_data) do
  # Get current version for rollback
  {:ok, current_version} = Sandbox.get_module_version(sandbox_id, MyModule)

  try do
    {:ok, :hot_reloaded} = Sandbox.hot_reload(sandbox_id, new_beam_data)
    verify_new_version(sandbox_id)
  rescue
    e ->
      Logger.error("Hot reload failed, rolling back: #{inspect(e)}")
      Sandbox.rollback_module(sandbox_id, MyModule, current_version)
      {:error, e}
  end
end
```

#### Pitfall 5: Memory Leaks from Old Code

**Problem**: Old code references are held, preventing garbage collection.

**Solution**: Ensure processes transition to new code by making explicit function calls:

```elixir
# In GenServer, explicitly call into new module
def handle_info(:code_change, state) do
  # This forces the process to use the new code
  {:noreply, __MODULE__.migrate_state(state)}
end
```

---

## Complete Working Examples

### Example 1: Plugin System with Hot Reload

```elixir
defmodule PluginManager do
  @moduledoc """
  Manages dynamically loadable plugins with hot reload support.
  """

  def load_plugin(plugin_id, plugin_path) do
    # Compile the plugin
    {:ok, compile_info} = Sandbox.compile_sandbox(plugin_path)

    # Create isolated sandbox
    {:ok, _sandbox} = Sandbox.create_sandbox(plugin_id, Plugin.Supervisor,
      sandbox_path: plugin_path
    )

    # Load all compiled modules
    Enum.each(compile_info.beam_files, fn beam_file ->
      beam_data = File.read!(beam_file)
      Sandbox.hot_reload(plugin_id, beam_data)
    end)

    {:ok, plugin_id}
  end

  def update_plugin(plugin_id, new_source_path) do
    # Compile new version
    {:ok, compile_info} = Sandbox.compile_sandbox(new_source_path)

    # Get current versions for potential rollback
    current_versions = get_current_versions(plugin_id, compile_info.beam_files)

    # Hot reload with state preservation
    results = Enum.map(compile_info.beam_files, fn beam_file ->
      beam_data = File.read!(beam_file)
      Sandbox.hot_reload(plugin_id, beam_data,
        state_handler: &plugin_state_migrator/3
      )
    end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, :updated}
    else
      # Rollback on failure
      rollback_versions(plugin_id, current_versions)
      {:error, :update_failed}
    end
  end

  def invoke_plugin(plugin_id, function, args) do
    Sandbox.run(plugin_id, fn ->
      apply(Plugin, function, args)
    end)
  end

  defp plugin_state_migrator(state, old_version, new_version) do
    state
    |> Map.put(:plugin_version, new_version)
    |> Map.put(:last_updated, DateTime.utc_now())
  end

  defp get_current_versions(plugin_id, beam_files) do
    Enum.map(beam_files, fn beam_file ->
      module = extract_module_name(beam_file)
      {:ok, version} = Sandbox.get_module_version(plugin_id, module)
      {module, version}
    end)
  end

  defp rollback_versions(plugin_id, versions) do
    Enum.each(versions, fn {module, version} ->
      Sandbox.rollback_module(plugin_id, module, version)
    end)
  end

  defp extract_module_name(beam_file) do
    beam_file
    |> Path.basename(".beam")
    |> String.to_atom()
  end
end
```

### Example 2: Live Code Editor with Version Control

```elixir
defmodule LiveCodeEditor do
  @moduledoc """
  A live code editor that supports hot reloading with undo/redo.
  """

  use GenServer

  defstruct [:sandbox_id, :current_version, :history]

  def start_link(sandbox_id) do
    GenServer.start_link(__MODULE__, sandbox_id, name: via(sandbox_id))
  end

  def update_code(sandbox_id, new_source) do
    GenServer.call(via(sandbox_id), {:update_code, new_source})
  end

  def undo(sandbox_id) do
    GenServer.call(via(sandbox_id), :undo)
  end

  def get_history(sandbox_id) do
    GenServer.call(via(sandbox_id), :get_history)
  end

  # Callbacks

  @impl true
  def init(sandbox_id) do
    state = %__MODULE__{
      sandbox_id: sandbox_id,
      current_version: 0,
      history: []
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:update_code, source}, _from, state) do
    case Sandbox.hot_reload_source(state.sandbox_id, source) do
      {:ok, :hot_reloaded} ->
        new_version = state.current_version + 1
        new_state = %{state |
          current_version: new_version,
          history: [{new_version, source, DateTime.utc_now()} | state.history]
        }
        {:reply, {:ok, new_version}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:undo, _from, state) do
    case state.history do
      [_current, {prev_version, prev_source, _} | rest] ->
        case Sandbox.hot_reload_source(state.sandbox_id, prev_source) do
          {:ok, :hot_reloaded} ->
            new_state = %{state |
              current_version: prev_version,
              history: [{prev_version, prev_source, DateTime.utc_now()} | rest]
            }
            {:reply, {:ok, prev_version}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :no_history}, state}
    end
  end

  @impl true
  def handle_call(:get_history, _from, state) do
    history_summary = Enum.map(state.history, fn {version, _source, timestamp} ->
      %{version: version, timestamp: timestamp}
    end)
    {:reply, {:ok, history_summary}, state}
  end

  defp via(sandbox_id), do: {:via, Registry, {CodeEditorRegistry, sandbox_id}}
end
```

### Example 3: A/B Testing with Hot Reload

```elixir
defmodule ABTestingFramework do
  @moduledoc """
  Run A/B tests by hot reloading different implementations.
  """

  def setup_ab_test(sandbox_id, variant_a_source, variant_b_source) do
    # Create two sandboxes for the variants
    sandbox_a = "#{sandbox_id}_variant_a"
    sandbox_b = "#{sandbox_id}_variant_b"

    {:ok, _} = Sandbox.create_sandbox(sandbox_a, ABTest.Supervisor)
    {:ok, _} = Sandbox.create_sandbox(sandbox_b, ABTest.Supervisor)

    {:ok, :hot_reloaded} = Sandbox.hot_reload_source(sandbox_a, variant_a_source)
    {:ok, :hot_reloaded} = Sandbox.hot_reload_source(sandbox_b, variant_b_source)

    {:ok, %{variant_a: sandbox_a, variant_b: sandbox_b}}
  end

  def run_test(test_config, user_id, function, args) do
    # Determine variant based on user_id
    variant = if :erlang.phash2(user_id, 100) < 50 do
      test_config.variant_a
    else
      test_config.variant_b
    end

    # Run in the appropriate sandbox
    Sandbox.run(variant, fn ->
      result = apply(TestModule, function, args)
      {variant, result}
    end)
  end

  def promote_variant(test_config, winning_variant, target_sandboxes) do
    # Get the winning variant's code
    {:ok, module_data} = Sandbox.ModuleVersionManager.export_sandbox_modules(
      winning_variant
    )

    # Hot reload all target sandboxes with the winning code
    results = Enum.map(target_sandboxes, fn sandbox_id ->
      Enum.map(module_data.modules, fn {_module, versions} ->
        latest = hd(versions)
        Sandbox.hot_reload(sandbox_id, latest.beam_data)
      end)
    end)

    {:ok, results}
  end
end
```

### Example 4: Cascading Hot Reload with Dependencies

```elixir
defmodule DependencyAwareReloader do
  @moduledoc """
  Hot reloads modules in the correct dependency order.
  """

  def reload_with_dependencies(sandbox_id, modules_to_reload) do
    # Calculate optimal reload order
    {:ok, ordered_modules} = Sandbox.ModuleVersionManager.calculate_reload_order(
      modules_to_reload,
      sandbox_id: sandbox_id
    )

    IO.puts("Reload order: #{inspect(ordered_modules)}")

    # Perform cascading reload
    {:ok, :reloaded} = Sandbox.ModuleVersionManager.cascading_reload(
      sandbox_id,
      ordered_modules,
      state_handler: &dependency_aware_migration/3,
      force_reload: false
    )
  end

  def parallel_reload_independent(sandbox_id, modules) do
    # Get dependency information
    {:ok, dep_graph} = Sandbox.ModuleVersionManager.get_module_dependencies(
      modules,
      sandbox_id: sandbox_id
    )

    # Check for circular dependencies
    case Sandbox.ModuleVersionManager.detect_circular_dependencies(dep_graph) do
      {:ok, :no_cycles} ->
        # Safe to reload in parallel where possible
        {:ok, :reloaded} = Sandbox.ModuleVersionManager.parallel_reload(
          sandbox_id,
          modules,
          timeout: 30_000
        )

      {:error, {:circular_dependency, cycles}} ->
        {:error, {:circular_dependencies_detected, cycles}}
    end
  end

  defp dependency_aware_migration(state, old_version, new_version) do
    # Track migration metadata
    %{state |
      __migration_history__: [
        %{
          from: old_version,
          to: new_version,
          migrated_at: DateTime.utc_now()
        }
        | Map.get(state, :__migration_history__, [])
      ]
    }
  end
end
```

---

## Summary

Hot reloading is a powerful feature that enables:

- **Zero-downtime deployments** with `Sandbox.hot_reload/3`
- **Convenient source updates** with `Sandbox.hot_reload_source/3`
- **Efficient batch operations** with `Sandbox.batch_hot_reload/3`
- **Safe version management** with automatic tracking and rollback
- **State preservation** with custom migration handlers

Key takeaways:

1. Always provide state handlers for structural state changes
2. Test migration functions thoroughly before production deployment
3. Use version management for safe rollback capabilities
4. Handle dependencies carefully with cascading or parallel reload
5. Monitor and log version transitions for debugging

For more information, see the [Sandbox documentation](https://hexdocs.pm/sandbox) and the related modules:

- `Sandbox.ModuleVersionManager` - Version tracking and rollback
- `Sandbox.StatePreservation` - Advanced state handling
- `Sandbox.IsolatedCompiler` - Safe code compilation
