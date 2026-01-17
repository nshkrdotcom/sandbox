# Sandbox Configuration Guide

This guide covers all configuration options available for the Sandbox library, from application-level settings to per-sandbox customization.

## Table of Contents

1. [Application Configuration](#application-configuration)
2. [Per-Sandbox Configuration](#per-sandbox-configuration)
3. [Resource Limits](#resource-limits)
4. [Security Profiles](#security-profiles)
5. [Compilation Options](#compilation-options)
6. [File Watching Configuration](#file-watching-configuration)
7. [Telemetry Configuration](#telemetry-configuration)
8. [Example Configurations](#example-configurations)

---

## Application Configuration

Application-level configuration is set in your `config/config.exs` file and applies globally to all sandboxes unless overridden.

### Basic Configuration

```elixir
# config/config.exs
config :sandbox,
  # ETS table names (for isolation in testing)
  table_names: %{
    sandboxes: :sandboxes,
    sandbox_monitors: :sandbox_monitors,
    module_versions: :apex_module_versions,
    isolation_contexts: :sandbox_isolation_contexts,
    sandbox_registry: :sandbox_registry,
    sandbox_modules: :sandbox_modules,
    sandbox_resources: :sandbox_resources,
    sandbox_security: :sandbox_security
  },

  # Service names (GenServer process names)
  services: %{
    manager: Sandbox.Manager,
    module_version_manager: Sandbox.ModuleVersionManager,
    process_isolator: Sandbox.ProcessIsolator,
    resource_monitor: Sandbox.ResourceMonitor,
    security_controller: Sandbox.SecurityController,
    file_watcher: Sandbox.FileWatcher,
    state_preservation: Sandbox.StatePreservation
  },

  # Table prefixes for dynamic tables
  table_prefixes: %{
    module_registry: "sandbox_modules",
    virtual_code: "sandbox_code"
  },

  # ETS persistence options
  cleanup_ets_on_stop: false,
  persist_ets_on_start: false
```

### ETS Table Configuration

The Sandbox library uses several ETS tables for state management:

| Table Name | Purpose |
|------------|---------|
| `sandboxes` | Main sandbox state storage |
| `sandbox_monitors` | Process monitor references |
| `module_versions` | Module version tracking |
| `isolation_contexts` | Process isolation context data |
| `sandbox_registry` | Sandbox metadata registry |
| `sandbox_modules` | Module tracking per sandbox |
| `sandbox_resources` | Resource usage data |
| `sandbox_security` | Security audit events |

#### Custom Table Names for Testing

When running tests in parallel, use custom table names to avoid conflicts:

```elixir
# test/test_helper.exs
Sandbox.Application.init_ets_tables(
  table_names: %{
    sandboxes: :"test_sandboxes_#{System.unique_integer([:positive])}",
    sandbox_monitors: :"test_monitors_#{System.unique_integer([:positive])}"
  }
)
```

### ETS Persistence Options

```elixir
config :sandbox,
  # When true, ETS tables are cleaned up on application stop
  cleanup_ets_on_stop: true,

  # When true, existing ETS tables are preserved on application start
  persist_ets_on_start: true
```

---

## Per-Sandbox Configuration

When creating a sandbox, you can specify per-instance configuration options:

```elixir
Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  # Path to sandbox source code
  sandbox_path: "/path/to/sandbox/code",

  # Compilation timeout in milliseconds (default: 30_000)
  compile_timeout: 60_000,

  # Resource limits map
  resource_limits: %{
    max_memory: 256 * 1024 * 1024,  # 256MB
    max_processes: 200,
    max_execution_time: 600_000,     # 10 minutes
    max_file_size: 20 * 1024 * 1024, # 20MB
    max_cpu_percentage: 75.0
  },

  # Security profile (:high, :medium, :low, or custom map)
  security_profile: :high,

  # Isolation mode (:process, :module, :hybrid, :ets)
  isolation_mode: :hybrid,

  # Isolation level for process isolation (:strict, :medium, :relaxed)
  isolation_level: :medium,

  # Communication mode between sandboxes
  communication_mode: :message_passing,

  # Enable automatic file watching and recompilation
  auto_reload: true,

  # Custom state migration function for hot-reloads
  state_migration_handler: &MyModule.migrate_state/3
)
```

### Isolation Modes

| Mode | Description |
|------|-------------|
| `:process` | Each sandbox runs in its own isolated process tree |
| `:module` | Module-level isolation with namespace transformation |
| `:hybrid` | Combines process and module isolation (recommended) |
| `:ets` | ETS-based isolation for shared state scenarios |

### Isolation Levels

| Level | Description | Spawn Options |
|-------|-------------|---------------|
| `:strict` | Maximum isolation with strict resource limits | `max_heap_size`, `off_heap` messages, `low` priority |
| `:medium` | Balanced isolation (default) | `max_heap_size`, `on_heap` messages |
| `:relaxed` | Minimal isolation for trusted code | Default spawn options |

### Communication Modes

| Mode | Description |
|------|-------------|
| `:none` | No inter-sandbox communication allowed |
| `:message_passing` | Sandboxes can send messages to each other (default) |
| `:shared_ets` | Sandboxes can share ETS tables |

---

## Resource Limits

Resource limits control the maximum resources a sandbox can consume.

### Available Limits

```elixir
resource_limits: %{
  # Maximum memory usage in bytes
  # Default: 128MB (128 * 1024 * 1024)
  max_memory: 128 * 1024 * 1024,

  # Maximum number of processes the sandbox can spawn
  # Default: 100
  max_processes: 100,

  # Maximum execution time in milliseconds
  # Default: 300_000 (5 minutes)
  max_execution_time: 300_000,

  # Maximum file size for compilation artifacts in bytes
  # Default: 10MB (10 * 1024 * 1024)
  max_file_size: 10 * 1024 * 1024,

  # Maximum CPU usage percentage
  # Default: 50.0
  max_cpu_percentage: 50.0
}
```

### Resource Monitoring

The `Sandbox.ResourceMonitor` module tracks resource usage in real-time:

```elixir
# Get current resource usage
{:ok, usage} = Sandbox.ResourceMonitor.sample_usage("my-sandbox")
# => %{memory: 45_000_000, processes: 15, message_queue: 0, uptime: 120_000}

# Check if limits are exceeded
case Sandbox.ResourceMonitor.check_limits("my-sandbox") do
  :ok ->
    IO.puts("Within limits")
  {:error, {:limit_exceeded, [:max_memory]}} ->
    IO.puts("Memory limit exceeded!")
end
```

### Resource Usage Tracking

The sandbox state includes real-time resource tracking:

```elixir
%{
  current_memory: 45_000_000,    # Current memory usage in bytes
  current_processes: 15,         # Current process count
  message_queue: 0,              # Total message queue length
  cpu_usage: 25.5,               # CPU usage percentage
  uptime: 120_000                # Uptime in milliseconds
}
```

---

## Security Profiles

Security profiles control what operations a sandbox can perform.

### Built-in Profiles

#### High Security (`:high`)

Most restrictive profile for untrusted code:

```elixir
%{
  isolation_level: :high,
  allowed_operations: [:basic_otp, :math, :string],
  restricted_modules: [:file, :os, :code, :system, :port, :node],
  audit_level: :full
}
```

#### Medium Security (`:medium`) - Default

Balanced profile for semi-trusted code:

```elixir
%{
  isolation_level: :medium,
  allowed_operations: [:basic_otp, :math, :string, :processes],
  restricted_modules: [:os, :port, :node],
  audit_level: :basic
}
```

#### Low Security (`:low`)

Minimal restrictions for trusted code:

```elixir
%{
  isolation_level: :low,
  allowed_operations: [:all],
  restricted_modules: [],
  audit_level: :basic
}
```

### Custom Security Profiles

Create custom profiles by passing a map:

```elixir
Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  security_profile: %{
    isolation_level: :medium,
    allowed_operations: [:basic_otp, :math, :string, :ecto],
    restricted_modules: [:os, :port, :node, :httpc],
    audit_level: :full
  }
)
```

### Audit Levels

| Level | Description |
|-------|-------------|
| `:full` | Log all operations and security events |
| `:basic` | Log security violations only |
| `:none` | No security auditing |

### Security Controller API

```elixir
# Register a sandbox with a security profile
Sandbox.SecurityController.register_sandbox("my-sandbox", :high)

# Check if an operation is allowed
case Sandbox.SecurityController.authorize_operation("my-sandbox", :file_read) do
  :ok -> # Operation allowed
  {:error, :operation_not_allowed} -> # Operation denied
end

# Record a security audit event
Sandbox.SecurityController.audit_event("my-sandbox", :suspicious_operation, %{
  module: SomeModule,
  function: :dangerous_function,
  timestamp: DateTime.utc_now()
})
```

---

## Compilation Options

The `Sandbox.IsolatedCompiler` module provides comprehensive compilation options.

### Basic Compilation

```elixir
Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  # Compilation timeout in milliseconds (default: 30_000)
  timeout: 60_000,

  # Memory limit for compilation in bytes (default: 256MB)
  memory_limit: 512 * 1024 * 1024,

  # Custom temporary directory
  temp_dir: "/tmp/my_sandbox_build",

  # Validate BEAM files after compilation (default: true)
  validate_beams: true,

  # Environment variables for compilation
  env: %{"MIX_ENV" => "prod"},

  # Compiler to use: :mix, :erlc, or :elixirc (default: :mix)
  compiler: :mix
)
```

### Incremental Compilation

Enable incremental compilation for faster rebuilds:

```elixir
Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  # Enable incremental compilation
  incremental: true,

  # Force full recompilation
  force_recompile: false,

  # Enable compilation cache
  cache_enabled: true,

  # Skip cache for this compilation
  skip_cache: false,

  # Analyze dependencies for smart recompilation
  dependency_analysis: true
)
```

### In-Process Compilation

For faster compilation without external processes:

```elixir
Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  # Compile in the current process (faster but less isolated)
  in_process: true,

  # Specific files to compile
  source_files: ["lib/my_module.ex", "lib/other_module.ex"],

  # Enable parallel compilation
  parallel: true,

  # Include debug info in BEAM files
  debug_info: true
)
```

### Security Scanning During Compilation

```elixir
Sandbox.IsolatedCompiler.compile_sandbox("/path/to/sandbox",
  # Enable security scanning of source code
  security_scan: true,

  # Modules that cannot be called
  restricted_modules: [:os, :port, :file],

  # Operations that are allowed
  allowed_operations: [:basic_otp, :math]
)
```

### Compilation Result

```elixir
{:ok, %{
  output: "Compilation output...",
  beam_files: ["/path/to/ebin/Module1.beam", "/path/to/ebin/Module2.beam"],
  app_file: "/path/to/ebin/my_app.app",
  compilation_time: 1234,  # milliseconds
  temp_dir: "/tmp/sandbox_abc123",
  warnings: [%{file: "lib/mod.ex", line: 10, message: "unused variable"}],
  incremental: true,
  cache_hit: false,
  changed_files: ["lib/changed_module.ex"]
}}
```

---

## File Watching Configuration

The `Sandbox.FileWatcher` module monitors file changes for automatic recompilation.

### Enabling Auto-Reload

```elixir
Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  sandbox_path: "/path/to/code",
  auto_reload: true
)
```

### File Watcher Features

The file watcher provides:

- Efficient file system monitoring
- Debounced compilation triggering
- Pattern-based file filtering
- Multi-sandbox watching coordination
- Performance optimization

### State Migration During Hot-Reload

When files change and code is reloaded, you can preserve state:

```elixir
Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  auto_reload: true,
  state_migration_handler: fn old_state, old_version, new_version ->
    # Transform state for new version
    case {old_version, new_version} do
      {1, 2} ->
        # Migrate from v1 to v2
        Map.put(old_state, :new_field, :default_value)
      _ ->
        old_state
    end
  end
)
```

---

## Telemetry Configuration

The Sandbox library emits telemetry events for observability.

### Available Events

```elixir
# Application lifecycle events
[:sandbox, :application, :start]
[:sandbox, :application, :stop]
```

### Setting Up Telemetry Handlers

```elixir
# In your application startup
:telemetry.attach_many(
  "sandbox-telemetry",
  [
    [:sandbox, :application, :start],
    [:sandbox, :application, :stop]
  ],
  fn event, measurements, metadata, config ->
    Logger.info("Sandbox event: #{inspect(event)}")
  end,
  nil
)
```

### Custom Telemetry Integration

```elixir
defmodule MyApp.SandboxTelemetry do
  require Logger

  def setup do
    :telemetry.attach_many(
      "myapp-sandbox-telemetry",
      [
        [:sandbox, :application, :start],
        [:sandbox, :application, :stop]
      ],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:sandbox, :application, :start], _measurements, _metadata, _config) do
    Logger.info("Sandbox application started")
  end

  def handle_event([:sandbox, :application, :stop], _measurements, _metadata, _config) do
    Logger.info("Sandbox application stopped")
  end
end
```

---

## Example Configurations

### Development Environment

Optimized for fast iteration and debugging:

```elixir
# config/dev.exs
config :sandbox,
  cleanup_ets_on_stop: false,
  persist_ets_on_start: true

# Creating a sandbox for development
Sandbox.Manager.create_sandbox("dev-sandbox", MyApp.Supervisor,
  sandbox_path: "/path/to/dev/code",
  compile_timeout: 120_000,
  resource_limits: %{
    max_memory: 512 * 1024 * 1024,  # 512MB - generous for debugging
    max_processes: 500,
    max_execution_time: 3_600_000,   # 1 hour
    max_file_size: 50 * 1024 * 1024
  },
  security_profile: :low,
  isolation_mode: :hybrid,
  isolation_level: :relaxed,
  auto_reload: true
)
```

### Production Environment

Optimized for security and resource management:

```elixir
# config/prod.exs
config :sandbox,
  cleanup_ets_on_stop: true,
  persist_ets_on_start: false

# Creating a sandbox for production
Sandbox.Manager.create_sandbox("prod-sandbox", MyApp.Supervisor,
  sandbox_path: "/path/to/prod/code",
  compile_timeout: 30_000,
  resource_limits: %{
    max_memory: 128 * 1024 * 1024,   # 128MB
    max_processes: 50,
    max_execution_time: 60_000,       # 1 minute
    max_file_size: 5 * 1024 * 1024,   # 5MB
    max_cpu_percentage: 25.0
  },
  security_profile: :high,
  isolation_mode: :hybrid,
  isolation_level: :strict,
  auto_reload: false
)
```

### Testing Environment

Optimized for isolation and parallel test execution:

```elixir
# config/test.exs
config :sandbox,
  cleanup_ets_on_stop: true,
  persist_ets_on_start: false

# test/support/sandbox_case.ex
defmodule MyApp.SandboxCase do
  use ExUnit.CaseTemplate

  setup do
    # Create unique table names for test isolation
    unique_id = System.unique_integer([:positive])

    table_names = %{
      sandboxes: :"test_sandboxes_#{unique_id}",
      sandbox_monitors: :"test_monitors_#{unique_id}",
      sandbox_registry: :"test_registry_#{unique_id}"
    }

    {:ok, _} = Sandbox.Application.init_ets_tables(table_names: table_names)

    on_exit(fn ->
      Sandbox.Application.cleanup_ets_tables(table_names: table_names)
    end)

    {:ok, table_names: table_names}
  end
end
```

### Multi-Tenant SaaS Environment

Each tenant gets their own isolated sandbox:

```elixir
defmodule MyApp.TenantSandbox do
  def create_tenant_sandbox(tenant_id) do
    Sandbox.Manager.create_sandbox(
      "tenant-#{tenant_id}",
      MyApp.TenantSupervisor,
      sandbox_path: "/tenants/#{tenant_id}/code",
      compile_timeout: 30_000,
      resource_limits: %{
        max_memory: 64 * 1024 * 1024,    # 64MB per tenant
        max_processes: 25,
        max_execution_time: 30_000,       # 30 seconds
        max_file_size: 2 * 1024 * 1024,   # 2MB
        max_cpu_percentage: 10.0          # 10% CPU per tenant
      },
      security_profile: %{
        isolation_level: :high,
        allowed_operations: [:basic_otp, :math, :string, :tenant_api],
        restricted_modules: [:file, :os, :code, :system, :port, :node, :httpc],
        audit_level: :full
      },
      isolation_mode: :hybrid,
      isolation_level: :strict,
      communication_mode: :none,  # No inter-tenant communication
      auto_reload: false
    )
  end
end
```

### Code Evaluation Service

For safely evaluating user-submitted code:

```elixir
defmodule MyApp.CodeEvaluator do
  def evaluate_code(code, user_id) do
    sandbox_id = "eval-#{user_id}-#{System.unique_integer([:positive])}"

    try do
      {:ok, _} = Sandbox.Manager.create_sandbox(
        sandbox_id,
        MyApp.EvalSupervisor,
        compile_timeout: 5_000,
        resource_limits: %{
          max_memory: 32 * 1024 * 1024,  # 32MB
          max_processes: 10,
          max_execution_time: 5_000,      # 5 seconds
          max_file_size: 1024 * 1024      # 1MB
        },
        security_profile: %{
          isolation_level: :high,
          allowed_operations: [:math, :string],
          restricted_modules: [:file, :os, :code, :system, :port, :node,
                               :application, :ets, :dets, :mnesia],
          audit_level: :full
        },
        isolation_level: :strict,
        communication_mode: :none
      )

      # Execute the code
      result = execute_in_sandbox(sandbox_id, code)

      {:ok, result}
    after
      # Always clean up
      Sandbox.Manager.destroy_sandbox(sandbox_id)
    end
  end
end
```

---

## Configuration Reference

### Complete Option Reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `sandbox_path` | `String.t()` | `"/tmp/sandbox"` | Path to sandbox source code |
| `compile_timeout` | `non_neg_integer()` | `30_000` | Compilation timeout (ms) |
| `resource_limits` | `map()` | See defaults | Resource limits map |
| `security_profile` | `atom() \| map()` | `:medium` | Security profile |
| `isolation_mode` | `atom()` | `:hybrid` | Isolation strategy |
| `isolation_level` | `atom()` | `:medium` | Process isolation level |
| `communication_mode` | `atom()` | `:message_passing` | Inter-sandbox communication |
| `auto_reload` | `boolean()` | `false` | Enable file watching |
| `state_migration_handler` | `function()` | `nil` | State migration function |

### Default Resource Limits

| Limit | Default Value | Description |
|-------|---------------|-------------|
| `max_memory` | `134_217_728` (128MB) | Maximum memory in bytes |
| `max_processes` | `100` | Maximum process count |
| `max_execution_time` | `300_000` (5 min) | Maximum execution time (ms) |
| `max_file_size` | `10_485_760` (10MB) | Maximum file size in bytes |
| `max_cpu_percentage` | `50.0` | Maximum CPU percentage |

---

## Troubleshooting

### Common Issues

**Sandbox creation fails with `:already_exists`**

```elixir
# Destroy existing sandbox first
Sandbox.Manager.destroy_sandbox("my-sandbox")
{:ok, _} = Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor, opts)
```

**Compilation timeout**

```elixir
# Increase timeout for large projects
Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  compile_timeout: 120_000  # 2 minutes
)
```

**Resource limit exceeded**

```elixir
# Check current usage
{:ok, usage} = Sandbox.ResourceMonitor.sample_usage("my-sandbox")
IO.inspect(usage, label: "Current usage")

# Increase limits if needed
Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  resource_limits: %{max_memory: 256 * 1024 * 1024}
)
```

**ETS table conflicts in tests**

```elixir
# Use unique table names per test
setup do
  unique_id = System.unique_integer([:positive])
  opts = [table_names: %{sandboxes: :"sandboxes_#{unique_id}"}]
  {:ok, opts: opts}
end
```
