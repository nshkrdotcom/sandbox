# Getting Started with Sandbox

This guide will walk you through setting up and using the Sandbox library to create isolated OTP applications with hot-reload capabilities in your Elixir project.

## What is Sandbox?

Sandbox enables you to create, manage, and hot-reload isolated OTP applications (sandboxes) within your Elixir system. Each sandbox runs with its own supervision tree in complete isolation, making it ideal for:

- **Plugin systems** - Load and update plugins without restarting your application
- **Learning environments** - Safely experiment with OTP patterns
- **Safe code execution** - Run untrusted code in isolated environments
- **Testing** - Test supervision strategies in isolation

## Prerequisites

Before you begin, ensure you have:

- Elixir 1.18 or later
- Erlang/OTP 26 or later
- A Mix project

## Installation

Add `sandbox` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:sandbox, "~> 0.1.0"}
  ]
end
```

Then fetch and compile the dependency:

```bash
mix deps.get
mix deps.compile
```

## Adding Sandbox to Your Supervision Tree

Sandbox needs to be started as part of your application's supervision tree. There are two approaches depending on your use case.

### Option 1: Add to an Existing Supervision Tree

Add `Sandbox` as a child in your application's supervisor:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Your other children...
      MyApp.Repo,
      MyAppWeb.Endpoint,

      # Add Sandbox to your supervision tree
      Sandbox
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Option 2: Start Sandbox Manually

For testing or scripting purposes, you can start Sandbox directly:

```elixir
# Start Sandbox manually
{:ok, _pid} = Sandbox.Application.start(:normal, [])
```

Or within an IEx session:

```elixir
iex> children = [Sandbox]
iex> {:ok, _sup} = Supervisor.start_link(children, strategy: :one_for_one)
```

## Creating Your First Sandbox

Now that Sandbox is running, let's create your first isolated sandbox.

### Step 1: Define a Supervisor Module

First, create a simple supervisor that will run inside your sandbox:

```elixir
defmodule MyApp.SandboxSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Add your sandbox's child processes here
      {MyApp.SandboxWorker, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

And a simple worker:

```elixir
defmodule MyApp.SandboxWorker do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok, %{count: 0}}
  end

  @impl true
  def handle_call(:get_count, _from, state) do
    {:reply, state.count, state}
  end

  @impl true
  def handle_cast(:increment, state) do
    {:noreply, %{state | count: state.count + 1}}
  end
end
```

### Step 2: Create the Sandbox

Create a sandbox using the supervisor module:

```elixir
{:ok, sandbox_info} = Sandbox.create_sandbox("my-first-sandbox", MyApp.SandboxSupervisor)
```

The function returns a map containing information about the created sandbox:

```elixir
%{
  id: "my-first-sandbox",
  status: :running,
  app_pid: #PID<0.123.0>,
  created_at: ~U[2024-01-15 10:30:00Z],
  # ... additional metadata
}
```

### Step 3: Verify the Sandbox is Running

Check that your sandbox was created successfully:

```elixir
{:ok, info} = Sandbox.get_sandbox_info("my-first-sandbox")
IO.inspect(info.status)  # => :running
```

## Basic Operations

### Listing All Sandboxes

View all active sandboxes in your system:

```elixir
sandboxes = Sandbox.list_sandboxes()

Enum.each(sandboxes, fn sandbox ->
  IO.puts("#{sandbox.id}: #{sandbox.status}")
end)
```

### Getting Sandbox Information

Retrieve detailed information about a specific sandbox:

```elixir
{:ok, info} = Sandbox.get_sandbox_info("my-first-sandbox")

IO.inspect(info, label: "Sandbox Info")
# Includes: id, status, app_pid, created_at, restart_count, resource_usage, etc.
```

### Getting the Sandbox Process ID

If you need direct access to the sandbox's main process:

```elixir
{:ok, pid} = Sandbox.get_sandbox_pid("my-first-sandbox")
Process.alive?(pid)  # => true
```

### Restarting a Sandbox

Restart a sandbox while preserving its configuration:

```elixir
{:ok, new_info} = Sandbox.restart_sandbox("my-first-sandbox")

IO.puts("Restart count: #{new_info.restart_count}")
```

The restart operation:
- Gracefully shuts down the existing sandbox
- Preserves the original configuration
- Creates a new sandbox with the same ID
- Increments the restart counter

### Destroying a Sandbox

When you're done with a sandbox, clean it up:

```elixir
:ok = Sandbox.destroy_sandbox("my-first-sandbox")
```

This operation:
- Terminates all sandbox processes gracefully
- Cleans up ETS tables
- Removes module versions
- Releases all sandbox resources

## Running Code in a Sandbox

Execute functions within a sandbox's execution context:

```elixir
# Run a function inside the sandbox
{:ok, result} = Sandbox.run("my-first-sandbox", fn ->
  # This code runs within the sandbox's context
  IO.puts("Hello from the sandbox!")
  :hello_from_sandbox
end)

IO.inspect(result)  # => :hello_from_sandbox
```

You can also specify a timeout:

```elixir
{:ok, result} = Sandbox.run("my-first-sandbox", fn ->
  # Long-running operation
  Process.sleep(1000)
  :done
end, timeout: 5000)
```

## Complete Working Example

Here's a complete example that demonstrates the full sandbox lifecycle:

```elixir
defmodule SandboxDemo do
  @moduledoc """
  A complete demonstration of Sandbox functionality.
  """

  def run do
    IO.puts("=== Sandbox Demo ===\n")

    # 1. Create a sandbox
    IO.puts("1. Creating sandbox...")
    {:ok, info} = Sandbox.create_sandbox("demo-sandbox", DemoSupervisor)
    IO.puts("   Created sandbox: #{info.id} (status: #{info.status})")

    # 2. List all sandboxes
    IO.puts("\n2. Listing sandboxes...")
    sandboxes = Sandbox.list_sandboxes()
    IO.puts("   Found #{length(sandboxes)} sandbox(es)")

    # 3. Get sandbox info
    IO.puts("\n3. Getting sandbox info...")
    {:ok, details} = Sandbox.get_sandbox_info("demo-sandbox")
    IO.puts("   Status: #{details.status}")
    IO.puts("   PID: #{inspect(details.app_pid)}")

    # 4. Run code in the sandbox
    IO.puts("\n4. Running code in sandbox...")
    {:ok, result} = Sandbox.run("demo-sandbox", fn ->
      Process.put(:sandbox_message, "Hello from inside!")
      Process.get(:sandbox_message)
    end)
    IO.puts("   Result: #{result}")

    # 5. Restart the sandbox
    IO.puts("\n5. Restarting sandbox...")
    {:ok, new_info} = Sandbox.restart_sandbox("demo-sandbox")
    IO.puts("   Restart count: #{new_info.restart_count}")

    # 6. Check resource usage
    IO.puts("\n6. Checking resource usage...")
    {:ok, usage} = Sandbox.resource_usage("demo-sandbox")
    IO.puts("   Resource usage: #{inspect(usage)}")

    # 7. Clean up
    IO.puts("\n7. Destroying sandbox...")
    :ok = Sandbox.destroy_sandbox("demo-sandbox")
    IO.puts("   Sandbox destroyed successfully")

    # 8. Verify cleanup
    IO.puts("\n8. Verifying cleanup...")
    case Sandbox.get_sandbox_info("demo-sandbox") do
      {:error, :not_found} -> IO.puts("   Sandbox no longer exists (expected)")
      _ -> IO.puts("   Warning: Sandbox still exists")
    end

    IO.puts("\n=== Demo Complete ===")
  end
end

# A minimal supervisor for the demo
defmodule DemoSupervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = []
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Run the demo:

```elixir
iex> SandboxDemo.run()
```

## Error Handling

Sandbox operations return tagged tuples for proper error handling:

```elixir
case Sandbox.create_sandbox("test", MySupervisor) do
  {:ok, info} ->
    IO.puts("Sandbox created: #{info.id}")

  {:error, {:already_exists, existing_info}} ->
    IO.puts("Sandbox already exists with status: #{existing_info.status}")

  {:error, {:validation_failed, errors}} ->
    IO.puts("Invalid configuration: #{inspect(errors)}")

  {:error, reason} ->
    IO.puts("Failed to create sandbox: #{inspect(reason)}")
end
```

Common error patterns:

| Error | Description |
|-------|-------------|
| `{:error, :not_found}` | The specified sandbox does not exist |
| `{:error, {:already_exists, info}}` | A sandbox with that ID already exists |
| `{:error, {:validation_failed, errors}}` | Invalid sandbox configuration |
| `{:error, :timeout}` | Operation timed out |
| `{:error, {:crashed, reason}}` | Sandbox process crashed |

## Configuration Options

When creating a sandbox, you can customize its behavior:

```elixir
{:ok, sandbox} = Sandbox.create_sandbox("configured-sandbox", MySupervisor,
  # Path to sandbox code directory (optional)
  sandbox_path: "/path/to/sandbox/code",

  # Compilation timeout in milliseconds
  compile_timeout: 60_000,

  # Resource limits
  resource_limits: %{
    max_memory: 64 * 1024 * 1024,  # 64MB
    max_execution_time: 30_000      # 30 seconds
  },

  # Security profile (:high, :medium, :low)
  security_profile: :medium,

  # Enable automatic file watching for hot reload
  auto_reload: false
)
```

## Next Steps

Now that you understand the basics, explore these advanced topics:

- **Hot Reloading** - Learn how to update running sandboxes without restart
  - See `Sandbox.hot_reload/3` for BEAM bytecode reloading
  - See `Sandbox.hot_reload_source/3` for source code reloading

- **Module Version Management** - Track and rollback module versions
  - `Sandbox.get_module_version/2` - Get current version
  - `Sandbox.list_module_versions/2` - List all versions
  - `Sandbox.rollback_module/3` - Rollback to previous version

- **Isolated Compilation** - Compile code in isolation
  - `Sandbox.compile_sandbox/2` - Compile a directory
  - `Sandbox.compile_file/2` - Compile a single file

- **Batch Operations** - Manage multiple sandboxes efficiently
  - `Sandbox.batch_create/2` - Create multiple sandboxes
  - `Sandbox.batch_destroy/2` - Destroy multiple sandboxes
  - `Sandbox.batch_run/3` - Run functions across sandboxes

For API reference, see the module documentation:
- `Sandbox` - Main API module
- `Sandbox.Manager` - Lifecycle management
- `Sandbox.IsolatedCompiler` - Compilation utilities
- `Sandbox.ModuleVersionManager` - Version tracking

## Troubleshooting

### Sandbox Won't Start

1. Ensure Sandbox is in your supervision tree
2. Check that the supervisor module exists and is valid
3. Review logs for startup errors

```elixir
# Check if Sandbox.Manager is running
Process.whereis(Sandbox.Manager) != nil
```

### Sandbox Crashes Immediately

1. Verify your supervisor's `init/1` callback is correct
2. Check child specifications in the supervisor
3. Look for errors in the application logs

### Hot Reload Fails

1. Ensure the BEAM file is valid
2. Check that the module name matches
3. Verify the sandbox is in `:running` status

## Getting Help

- Check the module documentation with `h Sandbox` in IEx
- Review the README for additional examples
- File issues on the GitHub repository

Happy sandboxing!
