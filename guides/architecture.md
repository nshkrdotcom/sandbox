# Sandbox Library Architecture Guide

This document provides a comprehensive overview of the Sandbox library architecture, detailing component responsibilities, data flow, and extension points for developers working with or extending the system.

## Table of Contents

1. [High-Level Architecture Overview](#high-level-architecture-overview)
2. [Component Responsibilities](#component-responsibilities)
3. [Data Flow and Process Relationships](#data-flow-and-process-relationships)
4. [ETS Tables and Their Purposes](#ets-tables-and-their-purposes)
5. [Supervision Strategy](#supervision-strategy)
6. [Extension Points](#extension-points)

---

## High-Level Architecture Overview

The Sandbox library provides a comprehensive runtime isolation system for Elixir applications, enabling safe execution of untrusted code with resource limits, security controls, and hot-reload capabilities.

### System Architecture Diagram

```
                                    +------------------+
                                    |   Application    |
                                    |     (Client)     |
                                    +--------+---------+
                                             |
                                             v
+------------------------------------------------------------------------------------+
|                              Sandbox.Application                                    |
|                                                                                    |
|  +------------------+  Initializes ETS Tables  +-------------------------------+   |
|  |  Telemetry       |<------------------------>|  ETS Tables                   |   |
|  |  Events          |                          |  - sandbox_registry           |   |
|  +------------------+                          |  - sandbox_modules            |   |
|                                                |  - sandbox_resources          |   |
|                                                |  - sandbox_security           |   |
|                                                +-------------------------------+   |
+------------------------------------------------------------------------------------+
                                             |
                                             v
+------------------------------------------------------------------------------------+
|                              Sandbox.Supervisor (one_for_one)                       |
|                                                                                    |
|  +----------------+  +---------------------+  +-------------------+                |
|  |    Manager     |  | ModuleVersionManager|  | ProcessIsolator   |                |
|  |  (GenServer)   |  |    (GenServer)      |  |   (GenServer)     |                |
|  +-------+--------+  +---------+-----------+  +---------+---------+                |
|          |                     |                        |                          |
|          v                     v                        v                          |
|  +----------------+  +---------------------+  +-------------------+                |
|  | ResourceMonitor|  | SecurityController  |  |   FileWatcher     |                |
|  |  (GenServer)   |  |    (GenServer)      |  |   (GenServer)     |                |
|  +----------------+  +---------------------+  +-------------------+                |
|                                                                                    |
|  +-------------------+                                                             |
|  | StatePreservation |                                                             |
|  |    (GenServer)    |                                                             |
|  +-------------------+                                                             |
+------------------------------------------------------------------------------------+
```

### Component Interaction Flow

```
+-------------------+       +-------------------+       +-------------------+
|                   |       |                   |       |                   |
|  Client Request   +------>+     Manager       +------>+ ProcessIsolator   |
|  (create_sandbox) |       |                   |       |                   |
|                   |       +--------+----------+       +---------+---------+
+-------------------+                |                            |
                                     |                            |
                                     v                            v
                    +----------------+----------------+   +-------+--------+
                    |                                 |   |                |
                    |       +------------------+      |   | Isolated       |
                    |       | ModuleVersion    |      |   | Supervisor     |
                    |       | Manager          |      |   | Tree           |
                    |       +------------------+      |   |                |
                    |                                 |   +----------------+
                    |       +------------------+      |
                    |       | ResourceMonitor  |      |
                    |       +------------------+      |
                    |                                 |
                    |       +------------------+      |
                    |       | SecurityController|     |
                    |       +------------------+      |
                    |                                 |
                    +---------------------------------+
```

---

## Component Responsibilities

### Manager (Sandbox.Manager)

The Manager is the central orchestration component responsible for the complete lifecycle of sandboxes.

**Location:** `/lib/sandbox/manager.ex`

#### Core Responsibilities

1. **Sandbox Lifecycle Management**
   - Creates new sandboxes with validation and resource setup
   - Destroys sandboxes with comprehensive cleanup
   - Restarts sandboxes with state preservation
   - Hot-reloads sandbox code without downtime

2. **Process Monitoring**
   - Monitors sandbox processes using Erlang monitors
   - Handles `DOWN` messages for crashed sandboxes
   - Maintains monitor reference mappings in ETS

3. **Configuration Validation**
   - Validates sandbox paths and directory structure
   - Validates resource limits (memory, processes, execution time)
   - Validates security profiles for consistency

4. **State Coordination**
   - Coordinates with other components (ResourceMonitor, SecurityController)
   - Manages sandbox state transitions (compiling, running, stopping, error)
   - Provides run context and hot-reload context for sandboxes

#### Key API Functions

```elixir
# Create a new sandbox
Sandbox.Manager.create_sandbox(sandbox_id, supervisor_module, opts)

# Destroy a sandbox with cleanup
Sandbox.Manager.destroy_sandbox(sandbox_id, opts)

# Restart with state preservation
Sandbox.Manager.restart_sandbox(sandbox_id, opts)

# Hot-reload with new code
Sandbox.Manager.hot_reload_sandbox(sandbox_id, new_beam_data, opts)

# Query sandbox information
Sandbox.Manager.get_sandbox_info(sandbox_id, opts)
Sandbox.Manager.list_sandboxes(opts)
```

#### Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `:sandbox_path` | Path to sandbox code directory | Auto-generated |
| `:compile_timeout` | Compilation timeout in ms | 30,000 |
| `:resource_limits` | Resource limits map | Medium profile |
| `:security_profile` | Security level (:high, :medium, :low) | :medium |
| `:isolation_mode` | Isolation type (:process, :module, :hybrid) | :hybrid |
| `:auto_reload` | Enable file watching | false |

---

### ProcessIsolator (Sandbox.ProcessIsolator)

Implements process-level isolation where each sandbox runs in its own isolated process context with separate supervision trees.

**Location:** `/lib/sandbox/process_isolator.ex`

#### Core Responsibilities

1. **Process Isolation**
   - Spawns isolated processes with configurable resource limits
   - Creates separate supervision trees per sandbox
   - Provides memory isolation with individual heap spaces

2. **Error Isolation**
   - Prevents cross-sandbox crashes
   - Monitors isolated processes for failures
   - Cleans up crashed contexts automatically

3. **Resource Enforcement**
   - Sets process spawn options (max_heap_size, priority)
   - Configures message queue behavior
   - Enforces isolation levels (strict, medium, relaxed)

4. **Inter-Sandbox Communication**
   - Manages communication modes (none, message_passing, shared_ets)
   - Routes messages to isolated sandbox processes
   - Handles communication authorization

#### Isolation Levels

```
+------------------+-----------------------------------------------------+
|  Isolation Level |  Configuration                                      |
+------------------+-----------------------------------------------------+
|  :strict         |  max_heap: 64MB, off_heap messages, low priority    |
|  :medium         |  max_heap: 128MB, on_heap messages, normal priority |
|  :relaxed        |  No heap limits, default settings                   |
+------------------+-----------------------------------------------------+
```

#### Key API Functions

```elixir
# Create an isolated context
ProcessIsolator.create_isolated_context(sandbox_id, supervisor_module, opts)

# Destroy an isolated context
ProcessIsolator.destroy_isolated_context(sandbox_id, opts)

# Get context information
ProcessIsolator.get_context_info(sandbox_id, opts)

# Send message to isolated sandbox
ProcessIsolator.send_message_to_sandbox(sandbox_id, message, opts)
```

---

### ResourceMonitor (Sandbox.ResourceMonitor)

Monitors and enforces resource limits for sandboxes, tracking memory usage, process counts, and execution time.

**Location:** `/lib/sandbox/resource_monitor.ex`

#### Core Responsibilities

1. **Resource Tracking**
   - Samples memory usage across sandbox process trees
   - Counts active processes per sandbox
   - Tracks message queue lengths
   - Measures uptime/execution time

2. **Limit Enforcement**
   - Checks resource usage against configured limits
   - Reports limit violations
   - Supports configurable thresholds

3. **Process Tree Traversal**
   - Recursively collects PIDs from supervisor hierarchies
   - Aggregates resource usage across all child processes
   - Handles process lifecycle changes safely

#### Resource Usage Structure

```elixir
%{
  memory: integer(),        # Total memory in bytes
  processes: integer(),     # Number of active processes
  message_queue: integer(), # Total queued messages
  uptime: integer()         # Milliseconds since start
}
```

#### Key API Functions

```elixir
# Register a sandbox for monitoring
ResourceMonitor.register_sandbox(sandbox_id, pid, limits, opts)

# Unregister a sandbox
ResourceMonitor.unregister_sandbox(sandbox_id, opts)

# Sample current resource usage
ResourceMonitor.sample_usage(sandbox_id, opts)

# Check if limits are exceeded
ResourceMonitor.check_limits(sandbox_id, opts)
```

#### Default Resource Limits

| Limit | Default Value | Description |
|-------|---------------|-------------|
| `:max_memory` | 128 MB | Maximum heap size |
| `:max_processes` | 100 | Maximum concurrent processes |
| `:max_execution_time` | 300,000 ms | Maximum runtime (5 minutes) |
| `:max_file_size` | 10 MB | Maximum file size |
| `:max_cpu_percentage` | 50% | Maximum CPU utilization |

---

### SecurityController (Sandbox.SecurityController)

Provides security controls and code analysis for safe execution within sandboxes.

**Location:** `/lib/sandbox/security_controller.ex`

#### Core Responsibilities

1. **Security Profiles**
   - Manages predefined profiles (high, medium, low)
   - Supports custom security profile configurations
   - Validates profile consistency

2. **Operation Authorization**
   - Authorizes operations based on security profile
   - Blocks restricted module access
   - Validates allowed operation categories

3. **Audit Logging**
   - Records security events to ETS
   - Timestamps all audit entries
   - Supports configurable audit levels

#### Security Profiles

```
+----------+-----------------------------------------------------------+
|  Profile |  Configuration                                            |
+----------+-----------------------------------------------------------+
|  :high   |  Restricted: file, os, code, system, port, node          |
|          |  Allowed: basic_otp, math, string                         |
|          |  Audit: full                                              |
+----------+-----------------------------------------------------------+
|  :medium |  Restricted: os, port, node                               |
|          |  Allowed: basic_otp, math, string, processes              |
|          |  Audit: basic                                             |
+----------+-----------------------------------------------------------+
|  :low    |  Restricted: none                                         |
|          |  Allowed: all                                              |
|          |  Audit: basic                                             |
+----------+-----------------------------------------------------------+
```

#### Key API Functions

```elixir
# Register sandbox with security profile
SecurityController.register_sandbox(sandbox_id, profile, opts)

# Authorize an operation
SecurityController.authorize_operation(sandbox_id, operation, opts)

# Record audit event
SecurityController.audit_event(sandbox_id, event, metadata, opts)
```

---

### ModuleVersionManager (Sandbox.ModuleVersionManager)

Tracks module versions and handles hot-swapping for sandbox applications with rollback capabilities and dependency tracking.

**Location:** `/lib/sandbox/module_version_manager.ex`

#### Core Responsibilities

1. **Version Tracking**
   - Maintains version history per module per sandbox
   - Stores BEAM binary data for each version
   - Calculates checksums for deduplication
   - Limits stored versions (default: 10 per module)

2. **Hot-Swapping**
   - Performs safe code hot-swapping
   - Preserves process state during swaps
   - Supports custom state migration handlers
   - Coordinates with dependent modules

3. **Dependency Management**
   - Extracts dependencies from BEAM files
   - Detects circular dependencies
   - Calculates optimal reload order
   - Supports cascading and parallel reloads

4. **Rollback Support**
   - Rolls back to previous module versions
   - Restores BEAM data from version history
   - Handles rollback on swap failures

#### Key API Functions

```elixir
# Register a new module version
ModuleVersionManager.register_module_version(sandbox_id, module, beam_data, opts)

# Hot-swap a module
ModuleVersionManager.hot_swap_module(sandbox_id, module, new_beam_data, opts)

# Rollback to a specific version
ModuleVersionManager.rollback_module(sandbox_id, module, target_version, opts)

# Get module dependencies
ModuleVersionManager.get_module_dependencies(modules, opts)

# Calculate reload order
ModuleVersionManager.calculate_reload_order(modules, opts)

# Perform cascading reload
ModuleVersionManager.cascading_reload(sandbox_id, modules, opts)
```

#### Module Version Structure

```elixir
%{
  sandbox_id: String.t(),
  module: atom(),
  version: non_neg_integer(),
  beam_data: binary(),
  loaded_at: DateTime.t(),
  dependencies: [atom()],
  checksum: String.t()
}
```

---

## Data Flow and Process Relationships

### Sandbox Creation Flow

```
Client                Manager              ProcessIsolator       ResourceMonitor
  |                      |                       |                      |
  |  create_sandbox()    |                       |                      |
  |--------------------->|                       |                      |
  |                      |                       |                      |
  |                      |  validate_config()    |                      |
  |                      |--+                    |                      |
  |                      |  |                    |                      |
  |                      |<-+                    |                      |
  |                      |                       |                      |
  |                      | create_isolated_context()                    |
  |                      |---------------------->|                      |
  |                      |                       |                      |
  |                      |                       |  spawn_isolated_process()
  |                      |                       |--+                   |
  |                      |                       |  |                   |
  |                      |                       |<-+                   |
  |                      |                       |                      |
  |                      |   {:ok, context}      |                      |
  |                      |<----------------------|                      |
  |                      |                       |                      |
  |                      |                register_sandbox()            |
  |                      |-------------------------------------------->|
  |                      |                       |                      |
  |                      |                       |       :ok            |
  |                      |<--------------------------------------------|
  |                      |                       |                      |
  |  {:ok, sandbox_info} |                       |                      |
  |<---------------------|                       |                      |
```

### Hot-Reload Flow

```
Client              Manager          ModuleVersionManager    StatePreservation
  |                    |                      |                      |
  |  hot_reload()      |                      |                      |
  |------------------>|                      |                      |
  |                    |                      |                      |
  |                    |  hot_swap_module()   |                      |
  |                    |--------------------->|                      |
  |                    |                      |                      |
  |                    |                      | capture_module_states()
  |                    |                      |--------------------->|
  |                    |                      |                      |
  |                    |                      |   {:ok, states}      |
  |                    |                      |<---------------------|
  |                    |                      |                      |
  |                    |                      | :code.load_binary()  |
  |                    |                      |--+                   |
  |                    |                      |  |                   |
  |                    |                      |<-+                   |
  |                    |                      |                      |
  |                    |                      | restore_states()     |
  |                    |                      |--------------------->|
  |                    |                      |                      |
  |                    |                      |   {:ok, :restored}   |
  |                    |                      |<---------------------|
  |                    |                      |                      |
  |                    | {:ok, :hot_swapped}  |                      |
  |                    |<---------------------|                      |
  |                    |                      |                      |
  | {:ok, :hot_reloaded}                      |                      |
  |<-------------------|                      |                      |
```

### Process Crash Handling Flow

```
Isolated Process         ProcessIsolator           Manager
       |                        |                      |
       | (crashes)              |                      |
       X                        |                      |
                                |                      |
       {:DOWN, ref, ...}        |                      |
       ----------------------->|                      |
                                |                      |
                                | cleanup_crashed_context()
                                |--+                   |
                                |  |                   |
                                |<-+                   |
                                |                      |
                                |                      |
       {:DOWN, ref, ...}        |                      |
       ------------------------------------------->   |
                                |                      |
                                | handle_sandbox_crash()
                                |                      |--+
                                |                      |  |
                                |                      |<-+
                                |                      |
                                | (cleanup ETS, monitors)
                                |                      |
```

---

## ETS Tables and Their Purposes

The Sandbox system uses multiple ETS tables for different purposes, all initialized during application startup.

### Table Overview

```
+----------------------+-------------+------------------------------------------+
|  Table Name          |  Type       |  Purpose                                 |
+----------------------+-------------+------------------------------------------+
|  sandbox_registry    |  set        |  Main registry for sandbox state/metadata|
|  sandbox_modules     |  bag        |  Module version tracking and metadata    |
|  sandbox_resources   |  set        |  Resource usage tracking                 |
|  sandbox_security    |  ordered_set|  Security events and audit log           |
|  sandboxes           |  set        |  Active sandbox information              |
|  sandbox_monitors    |  set        |  Monitor reference to sandbox mappings   |
|  isolation_contexts  |  set        |  Process isolation context data          |
|  module_versions     |  bag        |  Module version history                  |
+----------------------+-------------+------------------------------------------+
```

### Table Configuration

All tables are configured with:
- `:named_table` - Accessible by name
- `:public` - Accessible from any process
- `{:read_concurrency, true}` - Optimized for concurrent reads
- `{:write_concurrency, true}` - Optimized for concurrent writes

### sandbox_registry

**Purpose:** Central registry for sandbox state and metadata.

**Key Structure:** `{sandbox_id, sandbox_info}`

**Usage:**
- Quick lookup of sandbox status
- Application startup state tracking
- Cross-component state sharing

### sandbox_modules

**Purpose:** Module version tracking and metadata storage.

**Key Structure:** `{{sandbox_id, module}, version_data}`

**Usage:**
- Version history storage
- BEAM binary caching
- Dependency tracking

### sandbox_resources

**Purpose:** Real-time resource usage tracking.

**Key Structure:** `{sandbox_id, usage_map}`

**Usage:**
- Memory usage monitoring
- Process count tracking
- Limit enforcement

### sandbox_security

**Purpose:** Security events and audit logging.

**Key Structure:** `{{sandbox_id, entry_id}, audit_entry}`

**Usage:**
- Audit trail maintenance
- Security event correlation
- Compliance reporting

### isolation_contexts

**Purpose:** Process isolation context data.

**Key Structure:** `{sandbox_id, context_info}`

**Usage:**
- Isolated process tracking
- Resource limit storage
- Communication mode configuration

---

## Supervision Strategy

### Application Supervisor Tree

```
                    Sandbox.Supervisor
                    (strategy: :one_for_one)
                            |
        +-------------------+-------------------+
        |         |         |         |         |
        v         v         v         v         v
    Manager   ModuleVer   Process  Resource  Security
              Manager    Isolator  Monitor  Controller
                            |         |         |
                            v         v         v
                        FileWatcher  StatePreservation
```

### Supervision Strategy Details

**Strategy:** `:one_for_one`

Each child process is supervised independently. If one crashes, only that process is restarted, not siblings.

**Rationale:**
- Components are independent services
- Failure in one component should not affect others
- Resource Monitor crash should not restart Manager

### Child Start Order

1. **Sandbox.Manager** - Central orchestration (depends on ETS tables)
2. **Sandbox.ModuleVersionManager** - Version tracking
3. **Sandbox.ProcessIsolator** - Process isolation infrastructure
4. **Sandbox.ResourceMonitor** - Resource monitoring
5. **Sandbox.SecurityController** - Security controls
6. **Sandbox.FileWatcher** - File watching system
7. **Sandbox.StatePreservation** - State preservation system

### Restart Strategies Per Component

| Component | Restart | Reason |
|-----------|---------|--------|
| Manager | permanent | Core orchestration must always run |
| ModuleVersionManager | permanent | Version state must persist |
| ProcessIsolator | permanent | Isolation infrastructure required |
| ResourceMonitor | permanent | Continuous monitoring needed |
| SecurityController | permanent | Security must always be enforced |
| FileWatcher | permanent | Hot-reload depends on this |
| StatePreservation | permanent | State migration requires this |

---

## Extension Points

The Sandbox library provides several extension points for customization and integration.

### 1. Custom Security Profiles

Create custom security profiles by providing a map with required keys:

```elixir
custom_profile = %{
  isolation_level: :medium,
  allowed_operations: [:basic_otp, :math, :custom_operation],
  restricted_modules: [:file, :system],
  audit_level: :full,
  max_module_size: 2 * 1024 * 1024,
  allow_dynamic_code: false,
  allow_network_access: false,
  allow_file_system_access: :read_only
}

Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  security_profile: custom_profile
)
```

### 2. State Migration Handlers

Provide custom state migration during hot-reloads:

```elixir
state_handler = fn old_state, old_version, new_version ->
  # Transform state for new version
  Map.put(old_state, :migrated_from, old_version)
end

Sandbox.Manager.hot_reload_sandbox("my-sandbox", new_beam_data,
  state_handler: state_handler
)
```

### 3. Resource Limit Customization

Configure custom resource limits:

```elixir
custom_limits = %{
  max_memory: 256 * 1024 * 1024,  # 256MB
  max_processes: 200,
  max_execution_time: 600_000,    # 10 minutes
  max_file_size: 20 * 1024 * 1024,
  max_cpu_percentage: 75.0
}

Sandbox.Manager.create_sandbox("my-sandbox", MySupervisor,
  resource_limits: custom_limits
)
```

### 4. Isolation Mode Selection

Choose between isolation modes:

```elixir
# Process isolation (Phase 2 - full process separation)
Sandbox.Manager.create_sandbox("sandbox", Supervisor,
  isolation_mode: :process,
  isolation_level: :strict
)

# Module isolation (Phase 1 - namespace transformation)
Sandbox.Manager.create_sandbox("sandbox", Supervisor,
  isolation_mode: :module
)

# Hybrid isolation (combines both approaches)
Sandbox.Manager.create_sandbox("sandbox", Supervisor,
  isolation_mode: :hybrid
)
```

### 5. Telemetry Integration

The library emits telemetry events that can be attached to:

```elixir
:telemetry.attach(
  "sandbox-handler",
  [:sandbox, :application, :start],
  fn _event, _measurements, _metadata, _config ->
    # Handle sandbox start event
  end,
  nil
)
```

**Available Events:**
- `[:sandbox, :application, :start]` - Application startup
- `[:sandbox, :application, :stop]` - Application shutdown

### 6. Custom Table Names

Override default ETS table names for test isolation:

```elixir
# In config/test.exs
config :sandbox,
  table_names: %{
    sandbox_registry: :test_sandbox_registry,
    sandbox_modules: :test_sandbox_modules
  }

# Or per-call override
Sandbox.Manager.create_sandbox("test-sandbox", Supervisor,
  table_names: %{sandbox_registry: :isolated_registry}
)
```

### 7. Service Name Customization

Override service names for custom deployments:

```elixir
config :sandbox,
  services: %{
    manager: MyApp.CustomManager,
    resource_monitor: MyApp.CustomResourceMonitor
  }
```

---

## Appendix: Configuration Reference

### Application Environment Options

```elixir
config :sandbox,
  # ETS table names
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

  # Service process names
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

  # ETS lifecycle options
  cleanup_ets_on_stop: false,
  persist_ets_on_start: false
```

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2024 | Initial architecture documentation |
