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

<svg viewBox="0 0 720 480" xmlns="http://www.w3.org/2000/svg" style="max-width: 720px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="arrowhead" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#64748b"/>
    </marker>
  </defs>

  <!-- Client Application -->
  <rect x="280" y="16" width="160" height="48" rx="4" fill="#f8fafc" stroke="#e2e8f0" stroke-width="1.5"/>
  <text x="360" y="36" text-anchor="middle" font-size="11" font-weight="600" fill="#334155">Application</text>
  <text x="360" y="52" text-anchor="middle" font-size="10" fill="#64748b">(Client)</text>

  <!-- Arrow to Sandbox.Application -->
  <line x1="360" y1="64" x2="360" y2="88" stroke="#64748b" stroke-width="1.5" marker-end="url(#arrowhead)"/>

  <!-- Sandbox.Application Container -->
  <rect x="40" y="96" width="640" height="120" rx="6" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1.5"/>
  <text x="360" y="116" text-anchor="middle" font-size="12" font-weight="600" fill="#1e293b">Sandbox.Application</text>

  <!-- Telemetry Events -->
  <rect x="64" y="132" width="140" height="56" rx="4" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="134" y="156" text-anchor="middle" font-size="10" font-weight="500" fill="#334155">Telemetry</text>
  <text x="134" y="172" text-anchor="middle" font-size="10" fill="#64748b">Events</text>

  <!-- Bidirectional arrow -->
  <line x1="204" y1="160" x2="296" y2="160" stroke="#64748b" stroke-width="1" stroke-dasharray="4,2"/>
  <text x="250" y="152" text-anchor="middle" font-size="8" fill="#94a3b8">Initializes ETS Tables</text>

  <!-- ETS Tables -->
  <rect x="304" y="128" width="352" height="72" rx="4" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="480" y="148" text-anchor="middle" font-size="10" font-weight="500" fill="#334155">ETS Tables</text>
  <text x="400" y="166" text-anchor="start" font-size="9" fill="#64748b">• sandbox_registry</text>
  <text x="400" y="180" text-anchor="start" font-size="9" fill="#64748b">• sandbox_modules</text>
  <text x="520" y="166" text-anchor="start" font-size="9" fill="#64748b">• sandbox_resources</text>
  <text x="520" y="180" text-anchor="start" font-size="9" fill="#64748b">• sandbox_security</text>

  <!-- Arrow to Supervisor -->
  <line x1="360" y1="216" x2="360" y2="244" stroke="#64748b" stroke-width="1.5" marker-end="url(#arrowhead)"/>

  <!-- Sandbox.Supervisor Container -->
  <rect x="40" y="252" width="640" height="212" rx="6" fill="#f1f5f9" stroke="#cbd5e1" stroke-width="1.5"/>
  <text x="360" y="272" text-anchor="middle" font-size="12" font-weight="600" fill="#1e293b">Sandbox.Supervisor</text>
  <text x="360" y="286" text-anchor="middle" font-size="9" fill="#64748b">(strategy: :one_for_one)</text>

  <!-- Top row of GenServers -->
  <rect x="64" y="300" width="120" height="52" rx="4" fill="#fff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="124" y="322" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Manager</text>
  <text x="124" y="338" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>

  <rect x="200" y="300" width="160" height="52" rx="4" fill="#fff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="280" y="322" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ModuleVersionManager</text>
  <text x="280" y="338" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>

  <rect x="376" y="300" width="140" height="52" rx="4" fill="#fff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="446" y="322" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ProcessIsolator</text>
  <text x="446" y="338" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>

  <!-- Arrows down -->
  <line x1="124" y1="352" x2="124" y2="372" stroke="#94a3b8" stroke-width="1"/>
  <line x1="280" y1="352" x2="280" y2="372" stroke="#94a3b8" stroke-width="1"/>
  <line x1="446" y1="352" x2="446" y2="372" stroke="#94a3b8" stroke-width="1"/>

  <!-- Bottom row of GenServers -->
  <rect x="64" y="380" width="120" height="52" rx="4" fill="#fff" stroke="#10b981" stroke-width="1.5"/>
  <text x="124" y="402" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">ResourceMonitor</text>
  <text x="124" y="418" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>

  <rect x="200" y="380" width="160" height="52" rx="4" fill="#fff" stroke="#10b981" stroke-width="1.5"/>
  <text x="280" y="402" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">SecurityController</text>
  <text x="280" y="418" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>

  <rect x="376" y="380" width="140" height="52" rx="4" fill="#fff" stroke="#10b981" stroke-width="1.5"/>
  <text x="446" y="402" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">FileWatcher</text>
  <text x="446" y="418" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>

  <rect x="532" y="380" width="132" height="52" rx="4" fill="#fff" stroke="#10b981" stroke-width="1.5"/>
  <text x="598" y="402" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">StatePreservation</text>
  <text x="598" y="418" text-anchor="middle" font-size="9" fill="#64748b">(GenServer)</text>
</svg>

### Component Interaction Flow

<svg viewBox="0 0 680 320" xmlns="http://www.w3.org/2000/svg" style="max-width: 680px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="arrow-flow" markerWidth="10" markerHeight="7" refX="9" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#3b82f6"/>
    </marker>
  </defs>

  <!-- Client Request -->
  <rect x="24" y="24" width="140" height="56" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="94" y="48" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Client Request</text>
  <text x="94" y="64" text-anchor="middle" font-size="9" fill="#64748b">(create_sandbox)</text>

  <!-- Arrow to Manager -->
  <line x1="164" y1="52" x2="204" y2="52" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#arrow-flow)"/>

  <!-- Manager -->
  <rect x="212" y="24" width="140" height="56" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="282" y="56" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Manager</text>

  <!-- Arrow to ProcessIsolator -->
  <line x1="352" y1="52" x2="392" y2="52" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#arrow-flow)"/>

  <!-- ProcessIsolator -->
  <rect x="400" y="24" width="140" height="56" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="470" y="56" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ProcessIsolator</text>

  <!-- Arrow down from Manager -->
  <line x1="282" y1="80" x2="282" y2="116" stroke="#64748b" stroke-width="1.5"/>

  <!-- Arrow down from ProcessIsolator -->
  <line x1="470" y1="80" x2="470" y2="116" stroke="#64748b" stroke-width="1.5"/>

  <!-- Sub-components container -->
  <rect x="180" y="124" width="220" height="172" rx="6" fill="#f8fafc" stroke="#e2e8f0" stroke-width="1"/>

  <!-- ModuleVersionManager -->
  <rect x="204" y="144" width="168" height="36" rx="4" fill="#fff" stroke="#10b981" stroke-width="1"/>
  <text x="288" y="166" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">ModuleVersionManager</text>

  <!-- ResourceMonitor -->
  <rect x="204" y="192" width="168" height="36" rx="4" fill="#fff" stroke="#10b981" stroke-width="1"/>
  <text x="288" y="214" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">ResourceMonitor</text>

  <!-- SecurityController -->
  <rect x="204" y="240" width="168" height="36" rx="4" fill="#fff" stroke="#10b981" stroke-width="1"/>
  <text x="288" y="262" text-anchor="middle" font-size="10" font-weight="500" fill="#047857">SecurityController</text>

  <!-- Isolated Supervisor Tree -->
  <rect x="424" y="124" width="152" height="80" rx="6" fill="#fef3c7" stroke="#f59e0b" stroke-width="1.5"/>
  <text x="500" y="156" text-anchor="middle" font-size="10" font-weight="500" fill="#b45309">Isolated</text>
  <text x="500" y="172" text-anchor="middle" font-size="10" font-weight="500" fill="#b45309">Supervisor</text>
  <text x="500" y="188" text-anchor="middle" font-size="10" font-weight="500" fill="#b45309">Tree</text>
</svg>

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

<svg viewBox="0 0 600 140" xmlns="http://www.w3.org/2000/svg" style="max-width: 600px; font-family: system-ui, -apple-system, sans-serif;">
  <!-- Header row -->
  <rect x="0" y="0" width="120" height="36" fill="#1e293b"/>
  <rect x="120" y="0" width="480" height="36" fill="#1e293b"/>
  <text x="60" y="22" text-anchor="middle" font-size="11" font-weight="600" fill="#fff">Isolation Level</text>
  <text x="360" y="22" text-anchor="middle" font-size="11" font-weight="600" fill="#fff">Configuration</text>

  <!-- :strict row -->
  <rect x="0" y="36" width="120" height="32" fill="#fef2f2" stroke="#fecaca" stroke-width="1"/>
  <rect x="120" y="36" width="480" height="32" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="60" y="56" text-anchor="middle" font-size="10" font-weight="600" fill="#dc2626">:strict</text>
  <text x="360" y="56" text-anchor="middle" font-size="10" fill="#475569">max_heap: 64MB, off_heap messages, low priority</text>

  <!-- :medium row -->
  <rect x="0" y="68" width="120" height="32" fill="#fefce8" stroke="#fef08a" stroke-width="1"/>
  <rect x="120" y="68" width="480" height="32" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="60" y="88" text-anchor="middle" font-size="10" font-weight="600" fill="#ca8a04">:medium</text>
  <text x="360" y="88" text-anchor="middle" font-size="10" fill="#475569">max_heap: 128MB, on_heap messages, normal priority</text>

  <!-- :relaxed row -->
  <rect x="0" y="100" width="120" height="32" fill="#f0fdf4" stroke="#bbf7d0" stroke-width="1"/>
  <rect x="120" y="100" width="480" height="32" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="60" y="120" text-anchor="middle" font-size="10" font-weight="600" fill="#16a34a">:relaxed</text>
  <text x="360" y="120" text-anchor="middle" font-size="10" fill="#475569">No heap limits, default settings</text>
</svg>

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

<svg viewBox="0 0 640 220" xmlns="http://www.w3.org/2000/svg" style="max-width: 640px; font-family: system-ui, -apple-system, sans-serif;">
  <!-- Header row -->
  <rect x="0" y="0" width="80" height="36" fill="#1e293b"/>
  <rect x="80" y="0" width="560" height="36" fill="#1e293b"/>
  <text x="40" y="22" text-anchor="middle" font-size="11" font-weight="600" fill="#fff">Profile</text>
  <text x="360" y="22" text-anchor="middle" font-size="11" font-weight="600" fill="#fff">Configuration</text>

  <!-- :high row -->
  <rect x="0" y="36" width="80" height="56" fill="#fef2f2" stroke="#fecaca" stroke-width="1"/>
  <rect x="80" y="36" width="560" height="56" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="40" y="68" text-anchor="middle" font-size="10" font-weight="600" fill="#dc2626">:high</text>
  <text x="96" y="52" text-anchor="start" font-size="9" fill="#64748b">Restricted:</text>
  <text x="156" y="52" text-anchor="start" font-size="9" fill="#475569">file, os, code, system, port, node</text>
  <text x="96" y="66" text-anchor="start" font-size="9" fill="#64748b">Allowed:</text>
  <text x="156" y="66" text-anchor="start" font-size="9" fill="#475569">basic_otp, math, string</text>
  <text x="96" y="80" text-anchor="start" font-size="9" fill="#64748b">Audit:</text>
  <text x="156" y="80" text-anchor="start" font-size="9" fill="#475569">full</text>

  <!-- :medium row -->
  <rect x="0" y="92" width="80" height="56" fill="#fefce8" stroke="#fef08a" stroke-width="1"/>
  <rect x="80" y="92" width="560" height="56" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="40" y="124" text-anchor="middle" font-size="10" font-weight="600" fill="#ca8a04">:medium</text>
  <text x="96" y="108" text-anchor="start" font-size="9" fill="#64748b">Restricted:</text>
  <text x="156" y="108" text-anchor="start" font-size="9" fill="#475569">os, port, node</text>
  <text x="96" y="122" text-anchor="start" font-size="9" fill="#64748b">Allowed:</text>
  <text x="156" y="122" text-anchor="start" font-size="9" fill="#475569">basic_otp, math, string, processes</text>
  <text x="96" y="136" text-anchor="start" font-size="9" fill="#64748b">Audit:</text>
  <text x="156" y="136" text-anchor="start" font-size="9" fill="#475569">basic</text>

  <!-- :low row -->
  <rect x="0" y="148" width="80" height="56" fill="#f0fdf4" stroke="#bbf7d0" stroke-width="1"/>
  <rect x="80" y="148" width="560" height="56" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="40" y="180" text-anchor="middle" font-size="10" font-weight="600" fill="#16a34a">:low</text>
  <text x="96" y="164" text-anchor="start" font-size="9" fill="#64748b">Restricted:</text>
  <text x="156" y="164" text-anchor="start" font-size="9" fill="#475569">none</text>
  <text x="96" y="178" text-anchor="start" font-size="9" fill="#64748b">Allowed:</text>
  <text x="156" y="178" text-anchor="start" font-size="9" fill="#475569">all</text>
  <text x="96" y="192" text-anchor="start" font-size="9" fill="#64748b">Audit:</text>
  <text x="156" y="192" text-anchor="start" font-size="9" fill="#475569">basic</text>
</svg>

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

<svg viewBox="0 0 700 420" xmlns="http://www.w3.org/2000/svg" style="max-width: 700px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="seq-arrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#3b82f6"/>
    </marker>
    <marker id="seq-arrow-return" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#10b981"/>
    </marker>
  </defs>

  <!-- Participant headers -->
  <rect x="40" y="16" width="80" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="80" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Client</text>

  <rect x="200" y="16" width="80" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="240" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Manager</text>

  <rect x="360" y="16" width="100" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="410" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ProcessIsolator</text>

  <rect x="540" y="16" width="100" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="590" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ResourceMonitor</text>

  <!-- Lifelines -->
  <line x1="80" y1="48" x2="80" y2="400" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="240" y1="48" x2="240" y2="400" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="410" y1="48" x2="410" y2="400" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="590" y1="48" x2="590" y2="400" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>

  <!-- Message 1: create_sandbox() -->
  <line x1="80" y1="80" x2="232" y2="80" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#seq-arrow)"/>
  <text x="156" y="72" text-anchor="middle" font-size="9" fill="#1e40af">create_sandbox()</text>

  <!-- Message 2: validate_config() - self call -->
  <line x1="240" y1="110" x2="280" y2="110" stroke="#64748b" stroke-width="1"/>
  <line x1="280" y1="110" x2="280" y2="130" stroke="#64748b" stroke-width="1"/>
  <line x1="280" y1="130" x2="248" y2="130" stroke="#64748b" stroke-width="1" marker-end="url(#seq-arrow)"/>
  <text x="296" y="124" text-anchor="start" font-size="9" fill="#475569">validate_config()</text>

  <!-- Message 3: create_isolated_context() -->
  <line x1="240" y1="160" x2="402" y2="160" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#seq-arrow)"/>
  <text x="321" y="152" text-anchor="middle" font-size="9" fill="#1e40af">create_isolated_context()</text>

  <!-- Message 4: spawn_isolated_process() - self call -->
  <line x1="410" y1="190" x2="450" y2="190" stroke="#64748b" stroke-width="1"/>
  <line x1="450" y1="190" x2="450" y2="210" stroke="#64748b" stroke-width="1"/>
  <line x1="450" y1="210" x2="418" y2="210" stroke="#64748b" stroke-width="1" marker-end="url(#seq-arrow)"/>
  <text x="466" y="204" text-anchor="start" font-size="9" fill="#475569">spawn_isolated_process()</text>

  <!-- Message 5: {:ok, context} return -->
  <line x1="410" y1="245" x2="248" y2="245" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#seq-arrow-return)"/>
  <text x="329" y="237" text-anchor="middle" font-size="9" fill="#047857">{:ok, context}</text>

  <!-- Message 6: register_sandbox() -->
  <line x1="240" y1="280" x2="582" y2="280" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#seq-arrow)"/>
  <text x="411" y="272" text-anchor="middle" font-size="9" fill="#1e40af">register_sandbox()</text>

  <!-- Message 7: :ok return -->
  <line x1="590" y1="315" x2="248" y2="315" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#seq-arrow-return)"/>
  <text x="419" y="307" text-anchor="middle" font-size="9" fill="#047857">:ok</text>

  <!-- Message 8: {:ok, sandbox_info} return -->
  <line x1="240" y1="360" x2="88" y2="360" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#seq-arrow-return)"/>
  <text x="164" y="352" text-anchor="middle" font-size="9" fill="#047857">{:ok, sandbox_info}</text>
</svg>

### Hot-Reload Flow

<svg viewBox="0 0 720 480" xmlns="http://www.w3.org/2000/svg" style="max-width: 720px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="hr-arrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#3b82f6"/>
    </marker>
    <marker id="hr-arrow-return" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#10b981"/>
    </marker>
  </defs>

  <!-- Participant headers -->
  <rect x="32" y="16" width="72" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="68" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Client</text>

  <rect x="168" y="16" width="80" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="208" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Manager</text>

  <rect x="328" y="16" width="140" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="398" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ModuleVersionManager</text>

  <rect x="548" y="16" width="120" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="608" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">StatePreservation</text>

  <!-- Lifelines -->
  <line x1="68" y1="48" x2="68" y2="460" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="208" y1="48" x2="208" y2="460" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="398" y1="48" x2="398" y2="460" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="608" y1="48" x2="608" y2="460" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>

  <!-- Message 1: hot_reload() -->
  <line x1="68" y1="80" x2="200" y2="80" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#hr-arrow)"/>
  <text x="134" y="72" text-anchor="middle" font-size="9" fill="#1e40af">hot_reload()</text>

  <!-- Message 2: hot_swap_module() -->
  <line x1="208" y1="115" x2="390" y2="115" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#hr-arrow)"/>
  <text x="299" y="107" text-anchor="middle" font-size="9" fill="#1e40af">hot_swap_module()</text>

  <!-- Message 3: capture_module_states() -->
  <line x1="398" y1="150" x2="600" y2="150" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#hr-arrow)"/>
  <text x="499" y="142" text-anchor="middle" font-size="9" fill="#1e40af">capture_module_states()</text>

  <!-- Message 4: {:ok, states} return -->
  <line x1="608" y1="185" x2="406" y2="185" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#hr-arrow-return)"/>
  <text x="507" y="177" text-anchor="middle" font-size="9" fill="#047857">{:ok, states}</text>

  <!-- Message 5: :code.load_binary() - self call -->
  <line x1="398" y1="220" x2="444" y2="220" stroke="#64748b" stroke-width="1"/>
  <line x1="444" y1="220" x2="444" y2="245" stroke="#64748b" stroke-width="1"/>
  <line x1="444" y1="245" x2="406" y2="245" stroke="#64748b" stroke-width="1" marker-end="url(#hr-arrow)"/>
  <text x="462" y="236" text-anchor="start" font-size="9" fill="#475569">:code.load_binary()</text>

  <!-- Message 6: restore_states() -->
  <line x1="398" y1="280" x2="600" y2="280" stroke="#3b82f6" stroke-width="1.5" marker-end="url(#hr-arrow)"/>
  <text x="499" y="272" text-anchor="middle" font-size="9" fill="#1e40af">restore_states()</text>

  <!-- Message 7: {:ok, :restored} return -->
  <line x1="608" y1="315" x2="406" y2="315" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#hr-arrow-return)"/>
  <text x="507" y="307" text-anchor="middle" font-size="9" fill="#047857">{:ok, :restored}</text>

  <!-- Message 8: {:ok, :hot_swapped} return -->
  <line x1="398" y1="360" x2="216" y2="360" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#hr-arrow-return)"/>
  <text x="307" y="352" text-anchor="middle" font-size="9" fill="#047857">{:ok, :hot_swapped}</text>

  <!-- Message 9: {:ok, :hot_reloaded} return -->
  <line x1="208" y1="410" x2="76" y2="410" stroke="#10b981" stroke-width="1.5" stroke-dasharray="5,3" marker-end="url(#hr-arrow-return)"/>
  <text x="142" y="402" text-anchor="middle" font-size="9" fill="#047857">{:ok, :hot_reloaded}</text>
</svg>

### Process Crash Handling Flow

<svg viewBox="0 0 560 360" xmlns="http://www.w3.org/2000/svg" style="max-width: 560px; font-family: system-ui, -apple-system, sans-serif;">
  <defs>
    <marker id="crash-arrow" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#ef4444"/>
    </marker>
    <marker id="crash-arrow-gray" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto">
      <polygon points="0 0, 8 3, 0 6" fill="#64748b"/>
    </marker>
  </defs>

  <!-- Participant headers -->
  <rect x="40" y="16" width="100" height="32" rx="4" fill="#fef2f2" stroke="#ef4444" stroke-width="1.5"/>
  <text x="90" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#dc2626">Isolated Process</text>

  <rect x="220" y="16" width="100" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="270" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">ProcessIsolator</text>

  <rect x="400" y="16" width="100" height="32" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="450" y="36" text-anchor="middle" font-size="10" font-weight="500" fill="#1e40af">Manager</text>

  <!-- Lifelines -->
  <line x1="90" y1="48" x2="90" y2="100" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="270" y1="48" x2="270" y2="340" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>
  <line x1="450" y1="48" x2="450" y2="340" stroke="#cbd5e1" stroke-width="1" stroke-dasharray="4,3"/>

  <!-- Crash indicator -->
  <text x="90" y="88" text-anchor="middle" font-size="9" fill="#dc2626">(crashes)</text>
  <text x="90" y="108" text-anchor="middle" font-size="16" font-weight="bold" fill="#ef4444">X</text>

  <!-- Message 1: {:DOWN, ref, ...} to ProcessIsolator -->
  <line x1="90" y1="140" x2="262" y2="140" stroke="#ef4444" stroke-width="1.5" marker-end="url(#crash-arrow)"/>
  <text x="176" y="132" text-anchor="middle" font-size="9" fill="#dc2626">{:DOWN, ref, ...}</text>

  <!-- Self call: cleanup_crashed_context() -->
  <line x1="270" y1="170" x2="316" y2="170" stroke="#64748b" stroke-width="1"/>
  <line x1="316" y1="170" x2="316" y2="195" stroke="#64748b" stroke-width="1"/>
  <line x1="316" y1="195" x2="278" y2="195" stroke="#64748b" stroke-width="1" marker-end="url(#crash-arrow-gray)"/>
  <text x="332" y="186" text-anchor="start" font-size="9" fill="#475569">cleanup_crashed_context()</text>

  <!-- Message 2: {:DOWN, ref, ...} to Manager -->
  <line x1="90" y1="230" x2="442" y2="230" stroke="#ef4444" stroke-width="1.5" marker-end="url(#crash-arrow)"/>
  <text x="266" y="222" text-anchor="middle" font-size="9" fill="#dc2626">{:DOWN, ref, ...}</text>

  <!-- Self call: handle_sandbox_crash() -->
  <line x1="450" y1="260" x2="496" y2="260" stroke="#64748b" stroke-width="1"/>
  <line x1="496" y1="260" x2="496" y2="285" stroke="#64748b" stroke-width="1"/>
  <line x1="496" y1="285" x2="458" y2="285" stroke="#64748b" stroke-width="1" marker-end="url(#crash-arrow-gray)"/>
  <text x="512" y="276" text-anchor="start" font-size="9" fill="#475569">handle_sandbox_crash()</text>

  <!-- Note: cleanup ETS, monitors -->
  <rect x="380" y="310" width="140" height="24" rx="4" fill="#f8fafc" stroke="#e2e8f0" stroke-width="1"/>
  <text x="450" y="326" text-anchor="middle" font-size="9" fill="#64748b">(cleanup ETS, monitors)</text>
</svg>

---

## ETS Tables and Their Purposes

The Sandbox system uses multiple ETS tables for different purposes, all initialized during application startup.

### Table Overview

<svg viewBox="0 0 700 300" xmlns="http://www.w3.org/2000/svg" style="max-width: 700px; font-family: system-ui, -apple-system, sans-serif;">
  <!-- Header row -->
  <rect x="0" y="0" width="160" height="32" fill="#1e293b"/>
  <rect x="160" y="0" width="100" height="32" fill="#1e293b"/>
  <rect x="260" y="0" width="440" height="32" fill="#1e293b"/>
  <text x="80" y="20" text-anchor="middle" font-size="10" font-weight="600" fill="#fff">Table Name</text>
  <text x="210" y="20" text-anchor="middle" font-size="10" font-weight="600" fill="#fff">Type</text>
  <text x="480" y="20" text-anchor="middle" font-size="10" font-weight="600" fill="#fff">Purpose</text>

  <!-- Row 1 -->
  <rect x="0" y="32" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="32" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="32" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="52" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">sandbox_registry</text>
  <text x="210" y="52" text-anchor="middle" font-size="9" fill="#475569">set</text>
  <text x="276" y="52" text-anchor="start" font-size="9" fill="#475569">Main registry for sandbox state/metadata</text>

  <!-- Row 2 -->
  <rect x="0" y="62" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="62" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="62" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="82" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">sandbox_modules</text>
  <text x="210" y="82" text-anchor="middle" font-size="9" fill="#475569">bag</text>
  <text x="276" y="82" text-anchor="start" font-size="9" fill="#475569">Module version tracking and metadata</text>

  <!-- Row 3 -->
  <rect x="0" y="92" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="92" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="92" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="112" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">sandbox_resources</text>
  <text x="210" y="112" text-anchor="middle" font-size="9" fill="#475569">set</text>
  <text x="276" y="112" text-anchor="start" font-size="9" fill="#475569">Resource usage tracking</text>

  <!-- Row 4 -->
  <rect x="0" y="122" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="122" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="122" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="142" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">sandbox_security</text>
  <text x="210" y="142" text-anchor="middle" font-size="9" fill="#475569">ordered_set</text>
  <text x="276" y="142" text-anchor="start" font-size="9" fill="#475569">Security events and audit log</text>

  <!-- Row 5 -->
  <rect x="0" y="152" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="152" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="152" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="172" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">sandboxes</text>
  <text x="210" y="172" text-anchor="middle" font-size="9" fill="#475569">set</text>
  <text x="276" y="172" text-anchor="start" font-size="9" fill="#475569">Active sandbox information</text>

  <!-- Row 6 -->
  <rect x="0" y="182" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="182" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="182" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="202" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">sandbox_monitors</text>
  <text x="210" y="202" text-anchor="middle" font-size="9" fill="#475569">set</text>
  <text x="276" y="202" text-anchor="start" font-size="9" fill="#475569">Monitor reference to sandbox mappings</text>

  <!-- Row 7 -->
  <rect x="0" y="212" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="212" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="212" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="232" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">isolation_contexts</text>
  <text x="210" y="232" text-anchor="middle" font-size="9" fill="#475569">set</text>
  <text x="276" y="232" text-anchor="start" font-size="9" fill="#475569">Process isolation context data</text>

  <!-- Row 8 -->
  <rect x="0" y="242" width="160" height="30" fill="#eff6ff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="160" y="242" width="100" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <rect x="260" y="242" width="440" height="30" fill="#fff" stroke="#e2e8f0" stroke-width="1"/>
  <text x="80" y="262" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">module_versions</text>
  <text x="210" y="262" text-anchor="middle" font-size="9" fill="#475569">bag</text>
  <text x="276" y="262" text-anchor="start" font-size="9" fill="#475569">Module version history</text>
</svg>

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

<svg viewBox="0 0 640 220" xmlns="http://www.w3.org/2000/svg" style="max-width: 640px; font-family: system-ui, -apple-system, sans-serif;">
  <!-- Root supervisor -->
  <rect x="220" y="16" width="200" height="40" rx="6" fill="#1e293b" stroke="#0f172a" stroke-width="1.5"/>
  <text x="320" y="36" text-anchor="middle" font-size="11" font-weight="600" fill="#fff">Sandbox.Supervisor</text>
  <text x="320" y="50" text-anchor="middle" font-size="9" fill="#94a3b8">(strategy: :one_for_one)</text>

  <!-- Connecting line from supervisor -->
  <line x1="320" y1="56" x2="320" y2="76" stroke="#64748b" stroke-width="1.5"/>

  <!-- Horizontal connection line -->
  <line x1="64" y1="76" x2="576" y2="76" stroke="#64748b" stroke-width="1.5"/>

  <!-- Vertical lines to children -->
  <line x1="64" y1="76" x2="64" y2="96" stroke="#64748b" stroke-width="1.5"/>
  <line x1="168" y1="76" x2="168" y2="96" stroke="#64748b" stroke-width="1.5"/>
  <line x1="280" y1="76" x2="280" y2="96" stroke="#64748b" stroke-width="1.5"/>
  <line x1="392" y1="76" x2="392" y2="96" stroke="#64748b" stroke-width="1.5"/>
  <line x1="512" y1="76" x2="512" y2="96" stroke="#64748b" stroke-width="1.5"/>

  <!-- First row of children -->
  <rect x="16" y="100" width="96" height="36" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="64" y="122" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">Manager</text>

  <rect x="112" y="100" width="112" height="36" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="168" y="122" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">ModuleVerManager</text>

  <rect x="232" y="100" width="96" height="36" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="280" y="122" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">ProcessIsolator</text>

  <rect x="336" y="100" width="112" height="36" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="392" y="122" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">ResourceMonitor</text>

  <rect x="456" y="100" width="112" height="36" rx="4" fill="#eff6ff" stroke="#3b82f6" stroke-width="1.5"/>
  <text x="512" y="122" text-anchor="middle" font-size="9" font-weight="500" fill="#1e40af">SecurityController</text>

  <!-- Vertical lines to second row -->
  <line x1="280" y1="136" x2="280" y2="156" stroke="#94a3b8" stroke-width="1"/>
  <line x1="392" y1="136" x2="392" y2="156" stroke="#94a3b8" stroke-width="1"/>

  <!-- Second row of children -->
  <rect x="232" y="160" width="96" height="36" rx="4" fill="#f0fdf4" stroke="#10b981" stroke-width="1"/>
  <text x="280" y="182" text-anchor="middle" font-size="9" font-weight="500" fill="#047857">FileWatcher</text>

  <rect x="336" y="160" width="112" height="36" rx="4" fill="#f0fdf4" stroke="#10b981" stroke-width="1"/>
  <text x="392" y="182" text-anchor="middle" font-size="9" font-weight="500" fill="#047857">StatePreservation</text>
</svg>

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
