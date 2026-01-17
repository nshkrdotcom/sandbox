# Target Architecture: Evolution Runtime

## Design Principles

1. **Sandbox is the individual** - One sandbox = one evolved code variant
2. **Manager orchestrates lifecycle** - Create, evaluate, kill
3. **External systems drive evolution** - Mutation, selection, population management live outside sandbox
4. **Failure is expected** - Most mutations will crash; this is normal
5. **Observability over control** - We track more than we prevent

---

## Layer Model

```
┌─────────────────────────────────────────────────────────────────┐
│                    EXTERNAL: Evolution Engine                    │
│         (mutation operators, population, selection)              │
├─────────────────────────────────────────────────────────────────┤
│                    EXTERNAL: Fitness Evaluator                   │
│         (test runners, benchmarks, beamlens integration)         │
╠═════════════════════════════════════════════════════════════════╡
│                                                                  │
│                     SANDBOX (This Package)                       │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                      API Layer                              │ │
│  │    Sandbox.create/destroy/reload/evaluate/batch             │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                   Orchestration Layer                       │ │
│  │    Manager, PopulationRegistry, GarbageCollector            │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                    Execution Layer                          │ │
│  │    ProcessIsolator, ResourceEnforcer, SecurityGate          │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                     Code Layer                              │ │
│  │    Compiler, ModuleVersionManager, ModuleTransformer        │ │
│  └────────────────────────────────────────────────────────────┘ │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │                   Observability Layer                       │ │
│  │    Telemetry, FitnessRecorder, LineageTracker               │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Component Responsibilities

### API Layer

**Sandbox** (main module) - Public interface

```elixir
# Lifecycle
Sandbox.create_sandbox(id, supervisor, opts)
Sandbox.destroy_sandbox(id)

# Code loading
Sandbox.hot_reload(id, beam_binary, opts)
Sandbox.hot_reload_source(id, source_code, opts)  # NEW
Sandbox.rollback_module(id, module, version)

# Execution
Sandbox.run(id, fun)                              # NEW
Sandbox.run_with_timeout(id, fun, timeout)        # NEW

# Batch operations (for populations)
Sandbox.batch_create(configs)                     # NEW
Sandbox.batch_destroy(ids)                        # NEW
Sandbox.batch_evaluate(ids, fitness_fn)           # NEW

# Inspection
Sandbox.get_info(id)
Sandbox.get_module_version(id, module)
Sandbox.list_sandboxes()
```

### Orchestration Layer

**Manager** (existing, extended)

- Create/destroy sandbox lifecycle
- Process monitoring with DOWN handlers
- State machine: `:creating` → `:running` → `:error`/`:stopped`

**PopulationRegistry** (new)

- Track groups of related sandboxes
- Generation tracking (gen 1, gen 2, ...)
- Parent-child relationships
- Bulk operations on generations

**GarbageCollector** (new)

- Periodic cleanup of dead sandboxes
- Configurable retention (keep N generations)
- Artifact cleanup (temp directories, ETS entries)
- Memory pressure response

### Execution Layer

**ProcessIsolator** (existing, hardened)

- Create isolated supervision trees per sandbox
- Automatic supervisor injection
- Link management (unlink from Manager to prevent cascade)
- Process group tracking

**ResourceEnforcer** (new, replaces ResourceMonitor stub)

- Active enforcement, not just tracking
- Memory limit: kill sandbox if exceeded
- Process limit: reject spawn if exceeded
- Execution timeout: kill long-running operations
- Message queue: kill if backlog too large

**SecurityGate** (new, replaces SecurityController stub)

- Pre-execution validation
- Module allowlist/blocklist
- Function call interception (for known dangerous ops)
- Audit logging of security events

### Code Layer

**IsolatedCompiler** (existing)

- Multi-backend compilation
- Caching, incremental
- No changes needed

**ModuleVersionManager** (existing, minor extension)

- Version tracking up to N versions
- Checksums, dependencies
- Add: lineage metadata (parent version, mutation type)

**ModuleTransformer** (existing)

- AST-based module prefixing
- No changes needed

### Observability Layer

**Telemetry** (existing, extended)

```elixir
# Existing events
[:sandbox, :create, :start/:stop/:exception]
[:sandbox, :hot_reload, :start/:stop/:exception]

# New events for evolution
[:sandbox, :evaluate, :start/:stop/:exception]
[:sandbox, :batch, :start/:stop/:exception]
[:sandbox, :fitness, :computed]
[:sandbox, :killed, :resource_limit]
[:sandbox, :killed, :timeout]
[:sandbox, :gc, :collected]
```

**FitnessRecorder** (new)

- Record fitness evaluations per sandbox
- Store in ETS for fast access
- Emit telemetry for external aggregation

**LineageTracker** (new)

- Track parent → child relationships
- Mutation metadata (what changed)
- Query: "what's the lineage of sandbox X?"

---

## Data Models

### Extended SandboxState

```elixir
defmodule Sandbox.Models.SandboxState do
  defstruct [
    # Existing
    :id,
    :status,
    :config,
    :supervisor_pid,
    :process_monitor_ref,
    :created_at,
    :restart_count,
    :error,

    # New for evolution
    :generation,          # Which generation (0 = seed)
    :parent_id,           # Parent sandbox ID (nil for seed)
    :mutation_type,       # :crossover | :mutation | :seed
    :fitness,             # Latest fitness score
    :evaluated_at,        # When fitness was computed
    :lineage_depth        # How many generations from seed
  ]
end
```

### Fitness Result

```elixir
defmodule Sandbox.Models.FitnessResult do
  defstruct [
    :sandbox_id,
    :generation,
    :fitness_score,       # 0.0 - 1.0
    :components,          # %{correctness: 0.9, performance: 0.7, ...}
    :evaluated_at,
    :evaluation_time_ms,
    :test_results,        # Pass/fail details
    :error                # If evaluation crashed
  ]
end
```

### Population State

```elixir
defmodule Sandbox.Models.PopulationState do
  defstruct [
    :id,
    :generation,
    :sandbox_ids,         # List of member sandbox IDs
    :fitness_stats,       # %{min: 0.1, max: 0.9, mean: 0.5, ...}
    :created_at,
    :parent_population_id # For tracking generation lineage
  ]
end
```

---

## Lifecycle: Evolution Individual

```
┌──────────┐
│  Spawn   │ ← batch_create() or individual create_sandbox()
└────┬─────┘
     │
     ▼
┌──────────┐
│  Load    │ ← hot_reload() with mutated code
└────┬─────┘
     │
     ▼
┌──────────┐
│ Evaluate │ ← run() fitness function
└────┬─────┘
     │
     ├─── Fit ──→ Survives (maybe reproduces)
     │
     └─── Unfit ──→ destroy_sandbox() → GC cleanup
```

---

## Failure Handling

### Expected Failures (Normal Operation)

| Failure | Response |
|---------|----------|
| Mutation produces invalid syntax | Compilation fails, sandbox marked `:error` |
| Evolved code crashes on execution | Supervisor restarts, fitness = 0 |
| Code times out | Kill, fitness = 0 |
| Code exceeds memory | Kill, fitness = 0 |
| Code enters infinite loop | Timeout kills it |

### Unexpected Failures (Bugs)

| Failure | Response |
|---------|----------|
| Manager crashes | Supervisor restarts Manager, sandboxes orphaned |
| ETS table corruption | Application restart required |
| Node disconnect | Local sandboxes continue; distributed state inconsistent |

### Recovery Strategy

1. **Manager monitors all sandbox supervisors** - Automatic cleanup on crash
2. **Periodic GC sweep** - Find orphaned sandboxes, clean up
3. **Health check on startup** - Reconcile ETS with actual processes

---

## Resource Limits (Enforceable)

| Resource | Default | Enforcement Mechanism |
|----------|---------|----------------------|
| Memory | 128MB | Poll process info, kill if exceeded |
| Processes | 100 | Count children, reject spawn if exceeded |
| Execution | 5 min | Task.async_stream with timeout |
| Message queue | 10,000 | Poll mailbox size, kill if exceeded |

**Cannot enforce** (BEAM limitation):
- CPU time per sandbox (no scheduler hooks)
- File system quota (no OS hooks)
- Network bandwidth (no packet filtering)

---

## Concurrency Model

### Single Node

```
┌─────────────────────────────────────────────────┐
│                  Application                     │
│  ┌───────────────────────────────────────────┐  │
│  │              Sandbox.Supervisor            │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────────┐  │  │
│  │  │ Manager │ │ MVMgr   │ │ PopRegistry │  │  │
│  │  └─────────┘ └─────────┘ └─────────────┘  │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────────┐  │  │
│  │  │ Enforcer│ │ GC      │ │ FitnessRec  │  │  │
│  │  └─────────┘ └─────────┘ └─────────────┘  │  │
│  └───────────────────────────────────────────┘  │
│                                                  │
│  ┌─────────────────────────────────────────────┐│
│  │     DynamicSupervisor (Sandbox Instances)   ││
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐       ││
│  │  │ Sandbox │ │ Sandbox │ │ Sandbox │ ...   ││
│  │  │  evo-1  │ │  evo-2  │ │  evo-3  │       ││
│  │  └─────────┘ └─────────┘ └─────────┘       ││
│  └─────────────────────────────────────────────┘│
└─────────────────────────────────────────────────┘
```

### Multi-Node (Future)

Each node runs its own Sandbox application. Coordination via:
- External registry (Horde, pg)
- Migration: serialize state, create on target, destroy on source
- No global state in sandbox itself

---

## Configuration

```elixir
config :sandbox,
  # Resource defaults
  default_max_memory: 128 * 1024 * 1024,
  default_max_processes: 100,
  default_max_execution_time: 5 * 60_000,
  default_max_message_queue: 10_000,

  # GC settings
  gc_interval_ms: 60_000,
  gc_retain_generations: 3,

  # Enforcement
  enforcement_poll_interval_ms: 1_000,
  enforcement_enabled: true,

  # Telemetry
  emit_fitness_telemetry: true,
  emit_resource_telemetry: true,

  # Security
  security_profile: :medium,
  blocked_modules: [System, File, Port, :erlang]
```

---

## Integration Points

### For Evolution Engine (External)

```elixir
# Evolution engine calls sandbox
defmodule Evolution.Engine do
  def evaluate_generation(population_id, fitness_fn) do
    sandbox_ids = PopulationRegistry.get_members(population_id)

    # Batch evaluation
    results = Sandbox.batch_evaluate(sandbox_ids, fitness_fn)

    # Record and select
    Enum.map(results, &FitnessRecorder.record/1)
    select_survivors(results)
  end
end
```

### For Beamlens (Fitness Signal)

```elixir
# Beamlens monitors sandbox execution
defmodule Beamlens.SandboxSkill do
  def anomaly_handler(anomaly) do
    sandbox_id = extract_sandbox_id(anomaly)

    # Anomaly detected = fitness penalty
    Sandbox.FitnessRecorder.adjust(sandbox_id, -0.1, :anomaly)
  end
end
```

### For Telemetry Consumers

```elixir
# External dashboard
:telemetry.attach("dashboard", [:sandbox, :fitness, :computed], fn
  _event, measurements, metadata, _config ->
    Dashboard.update_fitness(metadata.sandbox_id, measurements.score)
end)
```

---

## Performance Targets

| Metric | Target | Rationale |
|--------|--------|-----------|
| Sandbox creation | <50ms | Fast generation turnover |
| Hot-reload | <100ms | Rapid mutation cycles |
| Batch create (100) | <2s | Population initialization |
| Batch evaluate (100) | <30s | Parallel fitness evaluation |
| GC cycle | <1s | Non-disruptive cleanup |
| Memory per sandbox | <50MB base | 100+ concurrent sandboxes |

---

## What Sandbox Does NOT Do

1. **Generate mutations** - External (LLM, genetic operators)
2. **Select survivors** - External (evolution engine)
3. **Manage populations** - External (evolution engine uses PopulationRegistry for tracking only)
4. **Store fitness history** - Records current, external stores history
5. **Decide when to evolve** - External triggers
6. **Distributed coordination** - External (Horde, pg)

Sandbox is the **execution substrate**, not the **evolution brain**.
