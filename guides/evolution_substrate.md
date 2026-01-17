# Evolution Substrate Guide

> **Sandbox: A Petri Dish for Code Evolution**

This guide describes the vision and roadmap for using Sandbox as the runtime substrate for evolving BEAM systems. It covers both current capabilities and planned features.

## Table of Contents

1. [Vision](#vision)
2. [What Evolution Substrate Means](#what-evolution-substrate-means)
3. [Current Capabilities](#current-capabilities)
4. [Planned Features](#planned-features)
5. [Integration Patterns](#integration-patterns)
6. [Example: Conceptual Evolution Cycle](#example-conceptual-evolution-cycle)
7. [Roadmap](#roadmap)
8. [Contributing](#contributing)

---

## Vision

Sandbox provides a foundational capability that no other mainstream runtime offers: **hot-reload code into supervised, isolated processes without restart**. This is the primitive on which genetic programming of live systems becomes possible.

### The Core Thesis

> "Your `sandbox` library isn't a plugin system. It's a **Petri dish for code evolution**."

Traditional plugin systems load code once and run it. Sandbox goes further: it creates isolated execution contexts where code can be continuously loaded, evaluated, replaced, and garbage collected. This makes it uniquely suited for:

- **Genetic Programming**: Evolve functions through mutation and selection
- **LLM-Driven Code Generation**: Safely evaluate AI-generated code variants
- **Self-Modifying Systems**: Build systems that improve themselves at runtime
- **Experimental Workloads**: Test code variations without affecting production

### Why BEAM?

The BEAM VM provides unique properties that make evolution workloads practical:

1. **Hot Code Loading**: Replace running code without process restart
2. **Process Isolation**: Failures in one process cannot corrupt another's state
3. **Supervision Trees**: Automatic recovery from crashes
4. **Lightweight Processes**: Spawn thousands of individuals efficiently
5. **Message Passing**: Clean communication between isolated components

Sandbox builds on these primitives to create a managed environment for code that is expected to fail, crash, and eventually improve.

---

## What Evolution Substrate Means

An evolution substrate must support the full lifecycle of evolved code. Sandbox addresses seven core requirements:

### 1. Spawn Individuals

Create isolated execution contexts for code variants. Each sandbox represents one "individual" in an evolutionary population.

```elixir
# Current capability
{:ok, _} = Sandbox.create_sandbox("evo-gen1-001", MySupervisor)
{:ok, _} = Sandbox.create_sandbox("evo-gen1-002", MySupervisor)
```

**Status**: Available today. Sandbox creation is fast (<50ms) and reliable.

### 2. Hot-Load Genomes

Inject mutated code into running sandboxes without restart. This is the core evolution primitive.

```elixir
# Load BEAM binary
{:ok, :hot_reloaded} = Sandbox.hot_reload("evo-gen1-001", beam_binary)

# Load source code directly
{:ok, :hot_reloaded} = Sandbox.hot_reload_source("evo-gen1-001", """
  defmodule Candidate do
    def fitness_target(x), do: x * x + 2 * x - 1
  end
""")
```

**Status**: Available today. Version management tracks up to 10 versions per module with rollback support.

### 3. Evaluate Fitness

Run tests, benchmarks, or fitness functions safely within the sandbox context.

```elixir
# Execute with timeout
{:ok, result} = Sandbox.run("evo-gen1-001", fn ->
  Candidate.fitness_target(42)
end, timeout: 5_000)
```

**Status**: Available today. The `run/3` function provides bounded execution with timeout enforcement.

### 4. Contain Failures

One bad mutation cannot crash the host. This is fundamental for evolution where most variants will fail.

```elixir
# Crashes are contained
{:error, {:crashed, _reason}} = Sandbox.run("evo-001", fn ->
  raise "Evolved code crashed"
end)

# Host continues running
{:ok, _} = Sandbox.get_sandbox_info("evo-001")  # Still accessible
```

**Status**: Partial. Process isolation via supervision trees works. Resource enforcement (memory limits, runaway processes) is planned.

### 5. Track Lineage

Know which version came from where. Essential for understanding what mutations improved fitness.

```elixir
# Version management provides lineage
{:ok, version} = Sandbox.get_module_version("evo-001", Candidate)
history = Sandbox.get_version_history("evo-001", Candidate)
# => %{current_version: 3, total_versions: 3, versions: [...]}
```

**Status**: Available for module versions. Generation and parent tracking (which sandbox spawned from which) is planned.

### 6. Garbage Collect

Clean up dead individuals efficiently. Evolution produces many short-lived variants.

```elixir
# Manual cleanup today
:ok = Sandbox.destroy_sandbox("evo-gen1-001")

# Batch operations for populations
results = Sandbox.batch_destroy(["evo-001", "evo-002", "evo-003"])
```

**Status**: Manual destruction works. Automatic garbage collection of abandoned sandboxes is planned.

### 7. Scale Horizontally

Distribute populations across BEAM nodes for larger experiments.

**Status**: Planned. Each node can run its own Sandbox application. Coordination via external registries (Horde, pg) is the target architecture.

---

## Current Capabilities

Sandbox provides solid foundations for evolution workloads today:

### Lifecycle Management

| Operation | API | Performance |
|-----------|-----|-------------|
| Create sandbox | `Sandbox.create_sandbox/3` | <50ms |
| Destroy sandbox | `Sandbox.destroy_sandbox/1` | <20ms |
| Restart sandbox | `Sandbox.restart_sandbox/1` | <100ms |
| Get info | `Sandbox.get_sandbox_info/1` | <1ms |
| List all | `Sandbox.list_sandboxes/0` | <10ms |

### Hot Reload with Version Management

| Operation | API | Notes |
|-----------|-----|-------|
| Reload BEAM | `Sandbox.hot_reload/3` | Binary bytecode |
| Reload source | `Sandbox.hot_reload_source/3` | Elixir source string |
| Get version | `Sandbox.get_module_version/2` | Current version number |
| List versions | `Sandbox.list_module_versions/2` | All tracked versions |
| Rollback | `Sandbox.rollback_module/3` | Return to previous version |
| Version history | `Sandbox.get_version_history/2` | Statistics and metadata |

### Bounded Execution

| Operation | API | Notes |
|-----------|-----|-------|
| Run function | `Sandbox.run/3` | Zero-arity function |
| With timeout | `timeout: ms` option | Kills on exceed |

### Batch Operations

| Operation | API | Notes |
|-----------|-----|-------|
| Batch create | `Sandbox.batch_create/2` | Parallel sandbox creation |
| Batch destroy | `Sandbox.batch_destroy/2` | Parallel cleanup |
| Batch run | `Sandbox.batch_run/3` | Parallel evaluation |
| Batch reload | `Sandbox.batch_hot_reload/3` | Parallel code loading |

Batch operations use `Task.async_stream` with configurable concurrency:

```elixir
# Create a population
configs = for i <- 1..100 do
  {"evo-#{i}", MySupervisor, []}
end

results = Sandbox.batch_create(configs, max_concurrency: 10)
```

### Module Transformation

Sandbox automatically namespaces modules to prevent collisions:

```elixir
# Original module name
MyModule

# Transformed to (example)
Sandbox_evo001_MyModule
```

This allows multiple sandboxes to load different versions of the same module name.

### State Preservation

Hot reload can preserve and migrate process state:

```elixir
{:ok, :hot_reloaded} = Sandbox.hot_reload("evo-001", beam_data,
  state_handler: fn old_state, old_version, new_version ->
    # Migrate state between versions
    %{old_state | schema_version: new_version}
  end
)
```

### Resource Monitoring

Track resource usage across sandboxes:

```elixir
{:ok, usage} = Sandbox.resource_usage("evo-001")
# => %{memory: 1234567, process_count: 5, ...}
```

**Note**: Resource tracking is available; enforcement of limits is planned.

---

## Planned Features

The following features are on the roadmap to complete the evolution substrate:

### Phase 1: Execution Foundations

**Priority: High**

1. **Execution timeout enforcement**: Ensure `max_execution_time` limits are enforced in all code paths
2. **Process isolation hardening**: Apply spawn options consistently to all sandbox processes
3. **Module loading consistency**: Reliable path from transformed source to executing code

### Phase 2: Safety and Throughput

**Priority: High**

1. **Resource enforcement**: Kill sandboxes that exceed memory or process limits
   ```elixir
   # Target API
   {:ok, _} = Sandbox.create_sandbox("evo-001", MySupervisor,
     resource_limits: %{
       max_memory: 64 * 1024 * 1024,  # 64MB - enforced
       max_processes: 50,              # enforced
       max_message_queue: 1000         # enforced
     }
   )
   ```

2. **Background garbage collection**: Automatic cleanup of crashed or abandoned sandboxes
   ```elixir
   # Target configuration
   config :sandbox,
     gc_interval_ms: 60_000,
     gc_retain_generations: 3
   ```

3. **Accurate resource aggregation**: Track memory and processes across the entire sandbox tree

### Phase 3: Evolution-Specific Features

**Priority: Medium**

1. **Population registry**: Track groups of related sandboxes
   ```elixir
   # Target API
   {:ok, _} = Sandbox.PopulationRegistry.create_population("gen-1", sandbox_ids)
   {:ok, members} = Sandbox.PopulationRegistry.get_members("gen-1")
   ```

2. **Generation tracking**: Know which generation each sandbox belongs to
   ```elixir
   # Target extended state
   %Sandbox.Models.SandboxState{
     generation: 5,
     parent_id: "evo-gen4-012",
     mutation_type: :crossover,
     lineage_depth: 5
   }
   ```

3. **Fitness recording**: Store evaluation results per sandbox
   ```elixir
   # Target API
   Sandbox.FitnessRecorder.record("evo-001", %{
     score: 0.85,
     components: %{correctness: 0.9, performance: 0.8},
     evaluated_at: DateTime.utc_now()
   })
   ```

### Phase 4: Observability

**Priority: Medium**

Extended telemetry events for evolution workloads:

```elixir
# Planned events
[:sandbox, :evaluate, :start/:stop/:exception]
[:sandbox, :batch, :start/:stop/:exception]
[:sandbox, :fitness, :computed]
[:sandbox, :killed, :resource_limit]
[:sandbox, :killed, :timeout]
[:sandbox, :gc, :collected]
```

### Phase 5: Security Hardening

**Priority: Lower (for trusted evolution)**

1. **AST scanning**: Detect dangerous operations before loading
2. **Module allowlists**: Restrict what modules evolved code can call
3. **Audit logging**: Track all security-relevant events

---

## Integration Patterns

Sandbox is the **execution substrate**, not the **evolution brain**. External systems handle mutation, selection, and population management.

### Pattern 1: External Evolution Engine

```
┌─────────────────────────────────────────────────────────────────┐
│                    EXTERNAL: Evolution Engine                    │
│         (mutation operators, population, selection)              │
├─────────────────────────────────────────────────────────────────┤
│                    EXTERNAL: Fitness Evaluator                   │
│         (test runners, benchmarks, monitoring)                   │
╠═════════════════════════════════════════════════════════════════╡
│                                                                  │
│                     SANDBOX (This Package)                       │
│                                                                  │
│    Spawn → Load → Execute → Contain → Track → Cleanup            │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

The evolution engine calls Sandbox APIs:

```elixir
defmodule Evolution.Engine do
  def run_generation(population, fitness_fn) do
    # 1. Create sandboxes for new individuals
    configs = Enum.map(population.individuals, fn ind ->
      {ind.id, EvolutionSupervisor, []}
    end)
    Sandbox.batch_create(configs)

    # 2. Load evolved code into each sandbox
    Enum.each(population.individuals, fn ind ->
      Sandbox.hot_reload_source(ind.id, ind.code)
    end)

    # 3. Evaluate fitness in parallel
    sandbox_ids = Enum.map(population.individuals, & &1.id)
    results = Sandbox.batch_run(sandbox_ids, fitness_fn, timeout: 10_000)

    # 4. Process results (external responsibility)
    select_survivors(results)

    # 5. Cleanup dead individuals
    dead_ids = get_unfit_ids(results)
    Sandbox.batch_destroy(dead_ids)
  end
end
```

### Pattern 2: LLM Code Generation

```elixir
defmodule LLMEvolution do
  def evolve_function(current_code, fitness_fn, llm_client) do
    sandbox_id = "llm-#{:erlang.unique_integer([:positive])}"

    # Create sandbox for evaluation
    {:ok, _} = Sandbox.create_sandbox(sandbox_id, LLMSupervisor)

    try do
      # Generate variation via LLM
      {:ok, new_code} = llm_client.mutate(current_code)

      # Load and evaluate
      case Sandbox.hot_reload_source(sandbox_id, new_code) do
        {:ok, :hot_reloaded} ->
          case Sandbox.run(sandbox_id, fitness_fn, timeout: 5_000) do
            {:ok, score} -> {:ok, new_code, score}
            {:error, reason} -> {:error, {:evaluation_failed, reason}}
          end

        {:error, reason} ->
          {:error, {:load_failed, reason}}
      end
    after
      Sandbox.destroy_sandbox(sandbox_id)
    end
  end
end
```

### Pattern 3: Monitoring Integration (Beamlens)

Monitoring tools can provide fitness signals:

```elixir
defmodule Beamlens.SandboxSkill do
  def anomaly_handler(anomaly) do
    # Extract sandbox ID from anomaly metadata
    case extract_sandbox_id(anomaly) do
      {:ok, sandbox_id} ->
        # Anomaly detected = fitness penalty
        # (External fitness recorder, not Sandbox's responsibility)
        FitnessTracker.penalize(sandbox_id, 0.1, :anomaly_detected)

      :error ->
        :ignore
    end
  end
end
```

### Pattern 4: Telemetry Consumers

Build dashboards and alerting:

```elixir
# Attach to sandbox telemetry
:telemetry.attach("evolution-dashboard",
  [:sandbox, :run, :stop],
  fn _event, measurements, metadata, _config ->
    Dashboard.record_evaluation(
      metadata.sandbox_id,
      measurements.duration,
      measurements.result
    )
  end,
  nil
)
```

---

## Example: Conceptual Evolution Cycle

This example demonstrates a complete evolution cycle using Sandbox.

### Setup

```elixir
defmodule EvolutionDemo do
  @population_size 10
  @generations 5
  @target_fn &(&1 * &1)  # Evolve toward x^2

  def run do
    # Initialize population with random candidates
    population = initialize_population()

    # Run evolution
    final_population = Enum.reduce(1..@generations, population, fn gen, pop ->
      IO.puts("Generation #{gen}")
      evolve_generation(pop, gen)
    end)

    # Report best individual
    best = Enum.max_by(final_population, & &1.fitness)
    IO.puts("Best fitness: #{best.fitness}")
    best
  end
```

### Population Initialization

```elixir
  defp initialize_population do
    for i <- 1..@population_size do
      sandbox_id = "evo-#{i}"

      # Create sandbox
      {:ok, _} = Sandbox.create_sandbox(sandbox_id, Task.Supervisor)

      # Generate random initial code
      code = generate_random_function()

      # Load into sandbox
      case Sandbox.hot_reload_source(sandbox_id, code) do
        {:ok, :hot_reloaded} ->
          %{id: sandbox_id, code: code, fitness: 0.0}

        {:error, _} ->
          # Bad initial code, use fallback
          fallback = "defmodule Candidate do\n  def f(x), do: x\nend"
          Sandbox.hot_reload_source(sandbox_id, fallback)
          %{id: sandbox_id, code: fallback, fitness: 0.0}
      end
    end
  end
```

### Fitness Evaluation

```elixir
  defp evaluate_fitness(individual) do
    fitness_fn = fn ->
      # Test candidate against target function
      test_cases = [-5, -2, 0, 1, 3, 7, 10]

      errors = Enum.map(test_cases, fn x ->
        expected = @target_fn.(x)
        actual = Candidate.f(x)
        abs(expected - actual)
      end)

      # Fitness is inverse of error (higher is better)
      total_error = Enum.sum(errors)
      if total_error == 0, do: 1.0, else: 1.0 / (1.0 + total_error)
    end

    case Sandbox.run(individual.id, fitness_fn, timeout: 1_000) do
      {:ok, score} -> %{individual | fitness: score}
      {:error, _} -> %{individual | fitness: 0.0}
    end
  end
```

### Selection and Reproduction

```elixir
  defp evolve_generation(population, _gen) do
    # Evaluate all individuals
    evaluated = Enum.map(population, &evaluate_fitness/1)

    # Select top performers
    survivors = evaluated
    |> Enum.sort_by(& &1.fitness, :desc)
    |> Enum.take(div(@population_size, 2))

    # Generate offspring through mutation
    offspring = Enum.flat_map(survivors, fn parent ->
      [
        parent,  # Keep parent
        mutate(parent)  # Create mutated child
      ]
    end)

    offspring
  end

  defp mutate(parent) do
    new_code = mutate_code(parent.code)  # Your mutation logic

    case Sandbox.hot_reload_source(parent.id, new_code) do
      {:ok, :hot_reloaded} ->
        %{parent | code: new_code, fitness: 0.0}

      {:error, _} ->
        # Mutation produced invalid code, keep parent
        parent
    end
  end
```

### Cleanup

```elixir
  defp cleanup(population) do
    ids = Enum.map(population, & &1.id)
    Sandbox.batch_destroy(ids)
  end
end
```

### Running the Demo

```elixir
# Start sandbox in your application
children = [Sandbox]
Supervisor.start_link(children, strategy: :one_for_one)

# Run evolution
EvolutionDemo.run()
```

---

## Roadmap

### Phase 0: Stabilization (Prerequisite)

Before MVP evolution features:

- [ ] Update dependencies for Elixir 1.19.4
- [ ] Ensure all tests pass with latest supertester
- [ ] Remove stubs with minimal working implementations
- [ ] Zero warnings, Dialyzer clean, Credo clean
- [ ] Config override hygiene (keyword lists and maps)
- [ ] State reset on startup by default

### Phase 1: Minimum Viable Evolution

Core features for controlled experiments:

- [ ] Execution timeout enforcement in all paths
- [ ] ProcessIsolator applies spawn_opt consistently
- [ ] Reliable module loading path
- [ ] Per-runtime StatePreservation overrides

### Phase 2: Safety and Throughput

Production-ready evolution:

- [ ] Resource enforcement (memory, processes, message queues)
- [ ] Accurate resource usage aggregation across sandbox trees
- [ ] Background garbage collection
- [ ] Performance benchmarks for 100+ concurrent sandboxes

### Phase 3: Evolution Features

Enhanced evolution support:

- [ ] Population registry and generation tracking
- [ ] Parent-child lineage tracking
- [ ] Fitness recording per sandbox
- [ ] Extended telemetry events

### Phase 4: Hardening

For untrusted code evolution:

- [ ] SecurityController enforcement
- [ ] AST scanning for dangerous operations
- [ ] Module allowlists/blocklists
- [ ] Comprehensive audit logging

---

## Contributing

Sandbox is open to contributions, especially in these areas:

### High-Impact Contributions

1. **Resource enforcement**: Implementing memory and process limits
2. **Test coverage**: Population-scale benchmarks and stress tests
3. **Documentation**: Example evolution engines and patterns
4. **Telemetry**: Dashboard templates for evolution monitoring

### How to Contribute

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/resource-enforcement`)
3. Ensure tests pass (`mix test`)
4. Run quality checks (`mix dialyzer && mix credo --strict`)
5. Submit a pull request

### Design Principles

When contributing, keep these principles in mind:

1. **Sandbox is the substrate, not the brain**: Mutation, selection, and population management belong in external systems
2. **Failure is expected**: Design for crashed sandboxes, not against them
3. **Observability over control**: Track and report; don't over-restrict
4. **BEAM-native**: Use OTP patterns, not foreign abstractions

### What Sandbox Does NOT Do

These are explicitly out of scope:

- Generate mutations (use LLMs, genetic operators externally)
- Select survivors (evolution engine responsibility)
- Store fitness history (record current only; external stores history)
- Distributed coordination (use Horde, pg externally)
- Persistence (use external storage for checkpoints)

---

## References

- [Getting Started](getting_started.md) - Installation and basic usage
- [Architecture](architecture.md) - System design and components
- `Sandbox` - API reference (run `mix docs` to generate)
- BEAM Hot Code Loading - Erlang/OTP documentation
- OTP Design Principles - Supervision and fault tolerance

---

*This document describes the vision and roadmap for Sandbox as an evolution substrate. Features marked as "planned" are subject to change based on implementation experience and community feedback.*
