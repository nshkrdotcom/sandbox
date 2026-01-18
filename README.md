<p align="center">
  <img src="assets/sandbox.svg" width="200" alt="Sandbox Logo">
</p>

# Sandbox

Isolated OTP application management with hot-reload capabilities for Elixir.

Sandbox enables you to create, manage, and hot-reload isolated OTP applications (sandboxes) within your Elixir system. Each sandbox runs with its own supervision tree and namespace-transformed modules, providing process-level separation suitable for plugin systems, development workflows, and learning environments.

## Features

- **Process Isolation**: Each sandbox has its own supervision tree and process hierarchy
- **Hot Reload**: Update running sandboxes without restarting
- **Version Management**: Track and rollback module versions
- **Fault Tolerance**: Sandbox crashes don't affect the host application
- **Resource Control**: Compile-time limits and process monitoring
- **Isolated Compilation**: Compile code in a separate process with configurable timeouts

## Documentation

Comprehensive guides are available to help you get the most out of Sandbox:

### Getting Started
- **[Getting Started](guides/getting_started.md)** - Installation, setup, and your first sandbox

### Core Guides
- **[Hot Reload](guides/hot_reload.md)** - Live code updates, version management, and state preservation
- **[Module Transformation](guides/module_transformation.md)** - Namespace isolation and virtual code tables
- **[Compilation](guides/compilation.md)** - Compilation backends, caching, and security
- **[Configuration](guides/configuration.md)** - All configuration options and security profiles

### Architecture
- **[Architecture](guides/architecture.md)** - System design, components, and extension points
- **[Evolution Substrate](guides/evolution_substrate.md)** - Vision for genetic programming and self-modifying systems

> **Note**: For API documentation, run `mix docs` to generate HTML documentation locally, or visit the [HexDocs](https://hexdocs.pm/sandbox).

## Installation

Add `sandbox` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sandbox, "~> 0.1.0"}
  ]
end
```

## Quick Start

### 1. Start Sandbox

Add Sandbox to your supervision tree:

```elixir
children = [
  Sandbox,
  # ... other children
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### 2. Create a Sandbox

```elixir
# Create a sandbox with a supervisor module
{:ok, sandbox} = Sandbox.create_sandbox("my-sandbox", MyApp.Supervisor)

# Or with custom options
{:ok, sandbox} = Sandbox.create_sandbox("plugin-1", :my_plugin,
  supervisor_module: MyPlugin.Supervisor,
  sandbox_path: "/path/to/plugin/code"
)
```

### 3. Hot Reload Code

```elixir
# Compile new code
{:ok, compile_info} = Sandbox.compile_file("updated_module.ex")

# Hot reload the module
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", 
  compile_info.beam_files |> hd() |> File.read!())
```

### 4. Manage Sandboxes

```elixir
# List all sandboxes
sandboxes = Sandbox.list_sandboxes()

# Get sandbox info
{:ok, info} = Sandbox.get_sandbox_info("my-sandbox")

# Restart a sandbox
{:ok, _} = Sandbox.restart_sandbox("my-sandbox")

# Destroy a sandbox
:ok = Sandbox.destroy_sandbox("my-sandbox")
```

## Advanced Usage

### Module Version Management

Sandbox tracks all module versions and supports rollback:

```elixir
# Check current version
{:ok, version} = Sandbox.get_module_version("my-sandbox", MyModule)

# List all versions
versions = Sandbox.list_module_versions("my-sandbox", MyModule)

# Rollback to a previous version
{:ok, :rolled_back} = Sandbox.rollback_module("my-sandbox", MyModule, 2)

# Get version history with statistics
history = Sandbox.get_version_history("my-sandbox", MyModule)
# => %{current_version: 3, total_versions: 3, versions: [...]}
```

### Custom State Migration

When hot-reloading GenServers, you can provide custom state migration logic:

```elixir
{:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data,
  state_handler: fn old_state, old_version, new_version ->
    # Migrate state from old version to new version
    %{old_state | version: new_version, upgraded_at: DateTime.utc_now()}
  end
)
```

### Isolated Compilation

Compile code in a separate process with configurable timeouts:

```elixir
# Compile a directory
{:ok, compile_info} = Sandbox.compile_sandbox("/path/to/sandbox",
  timeout: 60_000,
  validate_beams: true
)

# Compile a single file
{:ok, compile_info} = Sandbox.compile_file("my_module.ex")

# Access compilation results
compile_info.beam_files     # List of compiled BEAM files
compile_info.output         # Compiler output
compile_info.compilation_time # Time taken in milliseconds
```

## Use Cases

### Plugin Systems

Create a plugin system where each plugin runs in its own supervision tree:

```elixir
defmodule MyApp.PluginManager do
  def load_plugin(plugin_path) do
    plugin_id = Path.basename(plugin_path)
    
    # Create sandbox for the plugin
    {:ok, _} = Sandbox.create_sandbox(plugin_id, :plugin,
      supervisor_module: Plugin.Supervisor,
      sandbox_path: plugin_path
    )
    
    # Plugin is now running in its own supervision tree
  end
  
  def update_plugin(plugin_id, new_code_path) do
    # Compile new version
    {:ok, compile_info} = Sandbox.compile_sandbox(new_code_path)
    
    # Hot reload each module
    Enum.each(compile_info.beam_files, fn beam_file ->
      beam_data = File.read!(beam_file)
      Sandbox.hot_reload(plugin_id, beam_data)
    end)
  end
end
```

### Learning Environment

Create separate environments for experimenting with OTP patterns:

```elixir
defmodule LearningPlatform do
  def create_exercise_sandbox(user_id, exercise_code) do
    sandbox_id = "exercise_#{user_id}"

    # Write exercise code to temporary directory
    temp_dir = Path.join(System.tmp_dir!(), sandbox_id)
    File.mkdir_p!(temp_dir)
    File.write!(Path.join(temp_dir, "exercise.ex"), exercise_code)

    # Compile and run in sandbox
    {:ok, compile_info} = Sandbox.compile_sandbox(temp_dir)
    {:ok, _} = Sandbox.create_sandbox(sandbox_id, ExerciseSupervisor,
      sandbox_path: temp_dir
    )

    # Student's code now runs in its own supervision tree
  end
end
```

## Architecture

Sandbox is built on a modular architecture with clearly separated concerns:

```
┌─────────────────────────────────────────────────────────────┐
│                     Sandbox.Application                      │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │   Manager   │  │ ModuleVersion   │  │   Resource      │ │
│  │ (lifecycle) │  │    Manager      │  │   Monitor       │ │
│  └─────────────┘  └─────────────────┘  └─────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────────┐  ┌─────────────────┐ │
│  │  Security   │  │    Process      │  │   Isolated      │ │
│  │ Controller  │  │    Isolator     │  │   Compiler      │ │
│  └─────────────┘  └─────────────────┘  └─────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

Each sandbox has its own supervision tree and can be hot-reloaded independently without affecting others. For detailed architecture documentation, see the **[Architecture Guide](guides/architecture.md)**.

## Best Practices

1. **Set appropriate timeouts** for compilation and execution
2. **Monitor sandbox resource usage** in production
3. **Use version management** for safe rollbacks
4. **Test state migration handlers** thoroughly
5. **Clean up sandboxes** when no longer needed

## Limitations

**This is not a security sandbox.** Sandboxes share the same Erlang VM and are not suitable for running untrusted or potentially malicious code. All sandboxes share:

- The global code server and atom table
- Memory address space
- Scheduler infrastructure
- Network and file system access

Other limitations:

- Memory and resource limits are advisory, not enforced
- Security profiles audit operations but do not prevent them
- Hot-reload requires proper GenServer `code_change/3` implementation
- Some BEAM instructions can affect the entire VM

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -am 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Create a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.
