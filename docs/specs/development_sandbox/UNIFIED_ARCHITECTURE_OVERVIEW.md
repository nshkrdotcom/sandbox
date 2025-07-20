# Unified Apex Development Platform - Architecture Overview

## Purpose

This document provides a high-level architectural overview of the unified Apex Development Platform, which merges the security-focused Apex Sandbox with the developer-focused Development Sandbox Platform into a single, modular system. This overview references both specification sets to create a complete architectural vision.

## Reference Documents

### Development Sandbox Platform Specifications
- [`./01_overview.md`](./01_overview.md) - Development platform vision and concepts
- [`./02_architecture.md`](./02_architecture.md) - Development platform architecture
- [`./03_core_components.md`](./03_core_components.md) - Development component specifications
- [`./04_integration_patterns.md`](./04_integration_patterns.md) - Integration approaches
- [`./05_advanced_features.md`](./05_advanced_features.md) - Advanced development features
- [`./06_implementation_guide.md`](./06_implementation_guide.md) - Implementation roadmap

### Apex Sandbox Extraction Specifications (.kiro)
- [`../../.kiro/specs/sandbox-extraction-upgrade/requirements.md`](../../.kiro/specs/sandbox-extraction-upgrade/requirements.md) - Core sandbox requirements
- [`../../.kiro/specs/sandbox-extraction-upgrade/design.md`](../../.kiro/specs/sandbox-extraction-upgrade/design.md) - Sandbox technical design
- [`../../.kiro/specs/sandbox-extraction-upgrade/tasks.md`](../../.kiro/specs/sandbox-extraction-upgrade/tasks.md) - Implementation tasks

## Unified Architecture Vision

### Core Concept: Three Operational Modes

```elixir
defmodule Apex do
  @moduledoc """
  Unified platform supporting multiple operational modes:
  
  1. :isolation - Security-focused sandbox (from .kiro specs)
  2. :development - Developer-focused debugging (from dev sandbox specs)
  3. :hybrid - Combined features with configurable trade-offs
  """
  
  @type mode :: :isolation | :development | :hybrid
end
```

### Architectural Layers

```
┌─────────────────────────────────────────────────────────────────┐
│                    User Interface Layer                          │
│  ┌─────────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐ │
│  │   Web UI    │  │   CLI    │  │   IDE    │  │     API     │ │
│  │ (from ./05) │  │  Tools   │  │ Plugins  │  │ REST/WS/GQL │ │
│  └─────────────┘  └──────────┘  └──────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────────┘
                                 │
┌─────────────────────────────────┴───────────────────────────────┐
│                      Feature Layer                               │
│  ┌─────────────────────┐  ┌─────────────────────────────────┐  │
│  │  Security Features  │  │    Development Features         │  │
│  │  (from .kiro)       │  │    (from ./03-05)              │  │
│  ├─────────────────────┤  ├─────────────────────────────────┤  │
│  │ • Code Scanning     │  │ • Time-Travel Debugging       │  │
│  │ • Access Control    │  │ • Live State Manipulation     │  │
│  │ • Resource Limits   │  │ • Code Experimentation        │  │
│  │ • Audit Logging     │  │ • Distributed Debugging       │  │
│  └─────────────────────┘  └─────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
                                 │
┌─────────────────────────────────┴───────────────────────────────┐
│                    Core Engine Layer                             │
│          (Unified from both specifications)                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐   │
│  │   Module     │  │    State     │  │     Process        │   │
│  │  Management  │  │  Management  │  │   Orchestration    │   │
│  ├──────────────┤  ├──────────────┤  ├────────────────────┤   │
│  │ • Loading    │  │ • Bridge     │  │ • Isolation        │   │
│  │ • Transform  │  │ • Sync       │  │ • Monitoring       │   │
│  │ • Versions   │  │ • Preserve   │  │ • Communication    │   │
│  └──────────────┘  └──────────────┘  └────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                                 │
┌─────────────────────────────────┴───────────────────────────────┐
│                  Infrastructure Layer                            │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐   │
│  │   Storage    │  │  Clustering  │  │    Monitoring      │   │
│  │ • ETS Tables │  │ • Multi-node │  │ • Telemetry        │   │
│  │ • Persistent │  │ • Coord      │  │ • Metrics          │   │
│  └──────────────┘  └──────────────┘  └────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Component Mapping

### From Apex Sandbox (.kiro specs)

| Component | Purpose | Unified Role |
|-----------|---------|--------------|
| `Sandbox.Manager` | Lifecycle management | Core orchestrator for all modes |
| `Sandbox.IsolatedCompiler` | Secure compilation | Used in isolation and hybrid modes |
| `Sandbox.ModuleVersionManager` | Version tracking | Shared across all modes |
| `Sandbox.VirtualCodeTable` | ETS-based isolation | Isolation mode primary, optional others |
| `Sandbox.ProcessIsolator` | Process isolation | Isolation and hybrid modes |
| `Sandbox.ResourceMonitor` | Resource tracking | All modes with different limits |
| `Sandbox.SecurityController` | Security enforcement | Configurable per mode |
| `Sandbox.FileWatcher` | Auto-reload | All modes |
| `Sandbox.StatePreservation` | State persistence | Enhanced for development modes |

### From Development Sandbox Platform (./specs)

| Component | Purpose | Unified Role |
|-----------|---------|--------------|
| `DevSandbox.Harness` | App attachment | Development and hybrid modes |
| `DevSandbox.StateBridge` | State sync | Development mode primary |
| `DevSandbox.TimeTravel` | Debug recording | Development and hybrid modes |
| `DevSandbox.LiveState` | State manipulation | Development mode only |
| `DevSandbox.Experimentation` | Code testing | All modes with security checks |
| `DevSandbox.Debug` | Distributed debug | Development and hybrid modes |
| `DevSandbox.Performance` | Profiling | All modes with overhead config |
| `DevSandbox.Collaboration` | Team features | Development and hybrid modes |

## Mode-Based Feature Matrix

| Feature | Isolation Mode | Development Mode | Hybrid Mode |
|---------|----------------|------------------|-------------|
| **Security** |
| Module transformation | ✅ Required | ❌ Disabled | ✅ Configurable |
| Resource limits | ✅ Enforced | ⚠️ Warning only | ✅ Configurable |
| Code scanning | ✅ Strict | ⚠️ Advisory | ✅ Configurable |
| Audit logging | ✅ Full | ⚠️ Minimal | ✅ Configurable |
| **Development** |
| App attachment | ❌ Disabled | ✅ Full access | ✅ With limits |
| State manipulation | ❌ Forbidden | ✅ Unrestricted | ✅ Permission-based |
| Time-travel debug | ❌ Disabled | ✅ Full | ✅ Read-only |
| Live experimentation | ❌ Sandboxed only | ✅ Direct | ✅ Sandboxed |
| **Performance** |
| Overhead | ~5-10% | <1% | ~2-5% |
| Startup time | Slower (isolation) | Fast (direct) | Medium |

## Implementation Strategy

### Phase 1: Core Unification (References both specs)

1. **Extract Common Core** (from .kiro design.md + ./03_core_components.md)
   ```elixir
   defmodule Apex.Core do
     defmodule ModuleManager do
       # Unified from Sandbox.Manager + DevSandbox.Experimentation
     end
     
     defmodule StateManager do
       # Unified from StatePreservation + StateBridge
     end
     
     defmodule ProcessManager do
       # Unified from ProcessIsolator + Debug.Orchestrator
     end
   end
   ```

2. **Mode System** (new abstraction)
   ```elixir
   defmodule Apex.Mode do
     def configure(:isolation), do: load_kiro_config()
     def configure(:development), do: load_devsandbox_config()
     def configure(:hybrid), do: merge_configs()
   end
   ```

### Phase 2: Feature Integration

1. **Security Features** (from .kiro specs)
   - Implement ResourceMonitor (currently stub)
   - Complete SecurityController
   - Add FileWatcher functionality

2. **Development Features** (from ./specs)
   - Port time-travel debugging
   - Add live state manipulation
   - Implement collaboration

3. **Unified APIs**
   ```elixir
   # Backward compatible with .kiro design
   Sandbox.Manager.create_sandbox(id, module, opts)
   
   # New unified API
   Apex.create(id, module, mode: :isolation, opts)
   Apex.attach(app, mode: :development, opts)
   ```

### Phase 3: Advanced Integration

1. **Phoenix/LiveView** (from ./04_integration_patterns.md)
   - Mode-aware integration
   - Security policies for dev routes
   - Production safety

2. **Distributed Features** (from both specs)
   - ClusterTest integration (.kiro)
   - Distributed debugging (./specs)
   - Multi-node coordination

## Configuration Schema

```elixir
# Unified configuration supporting both specification sets
config :apex,
  # Global settings
  default_mode: :hybrid,
  cluster_enabled: true,
  
  # Mode configurations
  modes: [
    isolation: [
      # From .kiro specs
      module_transformation: true,
      process_isolation: :strict,
      resource_limits: %{
        max_processes: 1000,
        max_memory: 100_000_000,
        max_tables: 50
      },
      security_profile: :high
    ],
    
    development: [
      # From development sandbox specs
      attachment_strategy: :auto,
      debugging: %{
        time_travel: true,
        state_manipulation: true,
        distributed: true
      },
      collaboration: true
    ],
    
    hybrid: [
      # Merged configuration
      isolation: [:module_transformation, :audit],
      development: [:debugging, :profiling],
      permissions: %{
        state_edit: [:admin],
        time_travel: [:developer]
      }
    ]
  ]
```

## Migration Paths

### For Apex Sandbox Users (.kiro)
```elixir
# Old API continues to work
Sandbox.Manager.create_sandbox("test", MyModule)

# Internally mapped to
Apex.create("test", MyModule, mode: :isolation)
```

### For New Development Features
```elixir
# Start with existing sandbox
{:ok, sandbox} = Apex.create("dev", MyApp, mode: :isolation)

# Progressively enable features
Apex.enable_feature(sandbox, :debugging)
Apex.enable_feature(sandbox, :profiling)
Apex.transition_mode(sandbox, :hybrid)
```

## Testing Strategy

Combines testing approaches from both specifications:

1. **Security Testing** (from .kiro)
   - Isolation verification
   - Resource limit enforcement
   - Vulnerability scanning

2. **Development Testing** (from ./specs)
   - Feature functionality
   - Performance overhead
   - Integration scenarios

3. **Mode Transition Testing** (new)
   - Safe mode switching
   - Feature enable/disable
   - Permission enforcement

## Success Metrics

### From .kiro specs:
- ✅ Less than 1 second hot-reload latency
- ✅ Support for 100+ concurrent sandboxes
- ✅ Zero-downtime operations

### From development sandbox specs:
- ✅ 50% reduction in debug cycle time
- ✅ <5 second attachment time
- ✅ <1% overhead in development mode

### Unified platform:
- ✅ Single API for all use cases
- ✅ Mode switching without restart
- ✅ 95% code reuse between modes

## Conclusion

The unified Apex Development Platform combines the best of both specifications:
- **Production-ready** isolation and security from the .kiro specs
- **Developer-focused** productivity features from the development sandbox specs
- **Flexible deployment** through configurable operational modes
- **Progressive enhancement** allowing gradual feature adoption

This architecture ensures that Apex becomes the definitive platform for both secure code execution and advanced development workflows in the Elixir ecosystem.