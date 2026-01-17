# Integration Patterns: Sandbox in the Ecosystem

## Overview

Sandbox is a substrate, not a complete evolution system. This document shows how external systems integrate with sandbox to create full evolution pipelines.

---

## Pattern 1: Evolution Engine + Sandbox

The evolution engine handles mutation, selection, and population management. Sandbox handles execution and isolation.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Evolution Engine                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐  │
│  │   Mutator   │  │  Selector   │  │  Population Controller  │  │
│  │  (LLM/GP)   │  │ (Tournament)│  │   (Gen tracking)        │  │
│  └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘  │
│         │                │                       │               │
└─────────┼────────────────┼───────────────────────┼───────────────┘
          │                │                       │
          ▼                ▼                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                         Sandbox                                  │
│                                                                  │
│    hot_reload_source()   batch_evaluate()    PopulationRegistry │
│    run()                 FitnessRecorder     LineageTracker     │
│    batch_create()        GarbageCollector                       │
│    batch_destroy()                                              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Evolution Engine Responsibilities

```elixir
defmodule Evolution.Engine do
  @moduledoc """
  Orchestrates evolution using sandbox as substrate.
  """

  def run_generation(population_id, config) do
    # 1. Get current population
    {:ok, sandbox_ids} = Sandbox.PopulationRegistry.get_members(population_id)

    # 2. Evaluate fitness
    fitness_fn = build_fitness_fn(config.test_suite)
    results = Sandbox.batch_evaluate(sandbox_ids, fitness_fn)

    # 3. Record fitness
    Enum.each(results, fn {id, {:ok, score}} ->
      Sandbox.FitnessRecorder.record(%Sandbox.Models.FitnessResult{
        sandbox_id: id,
        fitness_score: score,
        generation: config.generation
      })
    end)

    # 4. Select survivors
    ranked = Sandbox.FitnessRecorder.rank(sandbox_ids)
    survivors = Enum.take(ranked, config.survivors_count) |> Enum.map(&elem(&1, 0))

    # 5. Generate offspring via external mutator
    offspring_configs = Mutator.generate_offspring(survivors, config)

    # 6. Create new sandboxes for offspring
    new_ids = create_offspring(offspring_configs)

    # 7. Advance generation
    Sandbox.PopulationRegistry.advance_generation(population_id, survivors ++ new_ids)

    # 8. Destroy unfit (GC will also clean up later)
    unfit = sandbox_ids -- survivors
    Sandbox.batch_destroy(unfit)

    {:ok, %{survivors: length(survivors), offspring: length(new_ids)}}
  end

  defp build_fitness_fn(test_suite) do
    fn sandbox_id ->
      # Run test suite inside sandbox
      results = Enum.map(test_suite, fn test ->
        case Sandbox.run(sandbox_id, test.function, timeout: test.timeout) do
          {:ok, result} -> {test.name, result == test.expected}
          {:error, _} -> {test.name, false}
        end
      end)

      # Calculate fitness
      passed = Enum.count(results, fn {_, pass} -> pass end)
      passed / length(results)
    end
  end

  defp create_offspring(configs) do
    configs
    |> Enum.map(fn config ->
      id = "evo-#{config.generation}-#{:erlang.unique_integer([:positive])}"
      {:ok, _} = Sandbox.create_sandbox(id, nil, parent_id: config.parent_id)
      {:ok, _} = Sandbox.hot_reload_source(id, config.source_code)
      id
    end)
  end
end
```

---

## Pattern 2: Beamlens as Fitness Signal

Beamlens monitors running code and detects anomalies. These anomalies become fitness signals.

```
┌─────────────────────────────────────────────────────────────────┐
│                       Test Environment                           │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    Evolved Code                              ││
│  │  (Running in sandbox, processing test workload)              ││
│  └──────────────────────────┬──────────────────────────────────┘│
│                              │                                   │
│                              │ telemetry, logs, metrics          │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                      Beamlens                                ││
│  │  - Monitors resource usage                                   ││
│  │  - Detects anomalies (memory leak, slow response, crashes)  ││
│  │  - Generates insights                                        ││
│  └──────────────────────────┬──────────────────────────────────┘│
│                              │                                   │
│                              │ anomaly notifications             │
│                              ▼                                   │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   Fitness Aggregator                         ││
│  │  - Combines test results + beamlens signals                  ││
│  │  - Anomaly count = fitness penalty                           ││
│  │  - Insight severity = fitness weight                         ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Integration Code

```elixir
defmodule Evolution.BeamlensFitness do
  @moduledoc """
  Use beamlens monitoring as fitness component.
  """

  def evaluate_with_monitoring(sandbox_id, workload, test_suite) do
    # Start monitoring this sandbox
    {:ok, _} = Beamlens.monitor_pid(get_sandbox_pid(sandbox_id))

    # Run workload
    start_time = System.monotonic_time(:millisecond)

    workload_result = Sandbox.run(sandbox_id, fn ->
      Enum.map(workload, &execute_operation/1)
    end, timeout: 60_000)

    elapsed = System.monotonic_time(:millisecond) - start_time

    # Run test suite
    test_results = run_tests(sandbox_id, test_suite)

    # Collect beamlens insights
    insights = Beamlens.Coordinator.get_recent_insights(sandbox_id)

    # Calculate composite fitness
    %{
      correctness: calculate_correctness(test_results),
      performance: calculate_performance(elapsed, workload),
      health: calculate_health(insights)
    }
    |> composite_score()
  end

  defp calculate_health(insights) do
    # No anomalies = 1.0, each anomaly reduces score
    base = 1.0
    penalty_per_insight = 0.1

    anomaly_count = Enum.count(insights, &(&1.type == :anomaly))
    max(0.0, base - anomaly_count * penalty_per_insight)
  end

  defp composite_score(components) do
    weights = %{correctness: 0.5, performance: 0.3, health: 0.2}

    Enum.reduce(components, 0.0, fn {key, value}, acc ->
      acc + value * weights[key]
    end)
  end
end
```

---

## Pattern 3: CNS-Guided Mutation

The CNS framework proposes reasoned mutations instead of random changes.

```
┌─────────────────────────────────────────────────────────────────┐
│                      CNS Mutation Pipeline                       │
│                                                                  │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │
│  │   Proposer   │───►│  Antagonist  │───►│  Synthesizer │       │
│  │              │    │              │    │              │       │
│  │ "Improve     │    │ "But that    │    │ "Here's a    │       │
│  │  this code"  │    │  breaks X"   │    │  resolution" │       │
│  └──────────────┘    └──────────────┘    └──────────────┘       │
│         ▲                                        │               │
│         │                                        │               │
│    parent code                           mutated code            │
│         │                                        │               │
└─────────┼────────────────────────────────────────┼───────────────┘
          │                                        │
          │                                        ▼
┌─────────┴────────────────────────────────────────────────────────┐
│                           Sandbox                                 │
│                                                                  │
│  ┌─────────────┐  hot_reload   ┌─────────────┐  evaluate         │
│  │   Parent    │──────────────►│   Child     │──────────►fitness │
│  │   sandbox   │               │   sandbox   │                   │
│  └─────────────┘               └─────────────┘                   │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Integration Code

```elixir
defmodule Evolution.CNSMutator do
  @moduledoc """
  Use CNS dialectical reasoning for code mutation.
  """

  alias CNS.{Proposer, Antagonist, Synthesizer}

  def mutate(parent_sandbox_id, mutation_goal, context) do
    # Get parent's code
    {:ok, parent_code} = get_sandbox_source(parent_sandbox_id)

    # Stage 1: Proposer generates candidate
    proposal = Proposer.propose(%{
      code: parent_code,
      goal: mutation_goal,
      context: context
    })

    # Stage 2: Antagonist critiques
    critique = Antagonist.critique(%{
      original: parent_code,
      proposal: proposal.code,
      test_suite: context.test_suite
    })

    # Stage 3: Synthesizer resolves (if needed)
    final_code = if critique.severity > 0 do
      Synthesizer.resolve(%{
        proposal: proposal,
        critique: critique
      }).code
    else
      proposal.code
    end

    # Create child sandbox with mutated code
    child_id = "#{parent_sandbox_id}-mut-#{:erlang.unique_integer([:positive])}"

    with {:ok, _} <- Sandbox.create_sandbox(child_id, nil, parent_id: parent_sandbox_id),
         {:ok, _} <- Sandbox.hot_reload_source(child_id, final_code) do
      {:ok, child_id, %{
        mutation_type: :cns_guided,
        proposal: proposal,
        critique: critique,
        final_code: final_code
      }}
    end
  end
end
```

---

## Pattern 4: Distributed Evolution (Island Model)

Multiple nodes run independent populations that occasionally exchange individuals.

```
┌─────────────────────────────────────────────────────────────────┐
│                          Node A                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                  Island Population A                         ││
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐                    ││
│  │  │ S-1 │ │ S-2 │ │ S-3 │ │ S-4 │ │ S-5 │ ...                ││
│  │  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘                    ││
│  └─────────────────────────────────────────────────────────────┘│
└───────────────────────────┬─────────────────────────────────────┘
                            │
                            │ migration (periodic)
                            │ (top N individuals)
                            │
┌───────────────────────────┼─────────────────────────────────────┐
│                           │         Node B                       │
│  ┌────────────────────────▼────────────────────────────────────┐│
│  │                  Island Population B                         ││
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐                    ││
│  │  │ S-1 │ │ S-2 │ │ S-3 │ │ S-4 │ │ S-5 │ ...                ││
│  │  └─────┘ └─────┘ └─────┘ └─────┘ └─────┘                    ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

### Migration Protocol

```elixir
defmodule Evolution.IslandMigration do
  @moduledoc """
  Periodic migration between island populations on different nodes.
  """

  def migrate(from_node, to_node, population_id, count) do
    # Get top individuals from source
    top = :rpc.call(from_node, Sandbox.FitnessRecorder, :top, [
      get_population_members(from_node, population_id),
      count
    ])

    # For each migrant
    Enum.map(top, fn {sandbox_id, fitness} ->
      # Serialize the code
      {:ok, source} = :rpc.call(from_node, __MODULE__, :export_sandbox, [sandbox_id])

      # Create on target node
      new_id = "migrant-#{sandbox_id}-#{System.unique_integer([:positive])}"

      :rpc.call(to_node, Sandbox, :create_sandbox, [new_id, nil, [
        parent_id: sandbox_id,
        mutation_type: :migration
      ]])

      :rpc.call(to_node, Sandbox, :hot_reload_source, [new_id, source])

      {new_id, fitness}
    end)
  end

  def export_sandbox(sandbox_id) do
    # Get all module sources from sandbox
    # (Implementation depends on how code is stored)
    {:ok, get_sandbox_source(sandbox_id)}
  end
end
```

---

## Pattern 5: Shadow Evolution (Mirror World)

Evolve code in shadow while production runs stable code. Promote when confident.

```
┌─────────────────────────────────────────────────────────────────┐
│                      Production Traffic                          │
│                             │                                    │
│              ┌──────────────┴──────────────┐                    │
│              │                             │                    │
│              ▼                             ▼                    │
│  ┌───────────────────────┐    ┌───────────────────────────────┐│
│  │   Production Code     │    │       Shadow Sandboxes        ││
│  │   (stable, tested)    │    │   (evolved variants)          ││
│  │                       │    │                               ││
│  │   process request     │    │   process same request        ││
│  │   return response     │    │   discard response            ││
│  │                       │    │   record fitness              ││
│  └───────────────────────┘    └───────────────────────────────┘│
│              │                             │                    │
│              │                             │                    │
│              ▼                             ▼                    │
│  ┌───────────────────────┐    ┌───────────────────────────────┐│
│  │      Response         │    │    Fitness Comparison         ││
│  │   (to user)           │    │                               ││
│  └───────────────────────┘    │  If shadow better:            ││
│                               │  → candidate for promotion    ││
│                               └───────────────────────────────┘│
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Integration Code

```elixir
defmodule Evolution.ShadowEvaluator do
  @moduledoc """
  Evaluate evolved code against production traffic without affecting users.
  """

  def shadow_evaluate(request, production_module, sandbox_id) do
    # Run production (this returns to user)
    task_prod = Task.async(fn ->
      start = System.monotonic_time(:microsecond)
      result = apply(production_module, :handle, [request])
      elapsed = System.monotonic_time(:microsecond) - start
      {result, elapsed}
    end)

    # Run shadow (this is discarded)
    task_shadow = Task.async(fn ->
      start = System.monotonic_time(:microsecond)

      result = Sandbox.run(sandbox_id, fn ->
        apply(get_sandbox_module(sandbox_id), :handle, [request])
      end, timeout: 5_000)

      elapsed = System.monotonic_time(:microsecond) - start
      {result, elapsed}
    end)

    # Get production result (must succeed)
    {prod_result, prod_time} = Task.await(task_prod)

    # Get shadow result (may fail)
    shadow_outcome = case Task.yield(task_shadow, 1_000) || Task.shutdown(task_shadow) do
      {:ok, {result, time}} -> {:ok, result, time}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end

    # Record comparison
    record_shadow_comparison(sandbox_id, %{
      production: %{result: prod_result, time_us: prod_time},
      shadow: shadow_outcome,
      match: shadow_outcome == {:ok, prod_result, shadow_time} for some shadow_time
    })

    # Return production result to caller
    prod_result
  end

  def should_promote?(sandbox_id) do
    comparisons = get_recent_comparisons(sandbox_id, 1000)

    # Criteria for promotion
    match_rate = count_matches(comparisons) / length(comparisons)
    avg_time_ratio = average_time_ratio(comparisons)  # shadow_time / prod_time

    match_rate > 0.99 and avg_time_ratio < 1.1
  end
end
```

---

## Pattern 6: Beamlens Skill Evolution

Evolve beamlens operator skills themselves.

```
┌─────────────────────────────────────────────────────────────────┐
│                  Beamlens Skill Evolution                        │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                 Original Skill Code                          ││
│  │  defmodule Beamlens.Skill.Memory do                         ││
│  │    def investigate(anomaly), do: ...                        ││
│  │  end                                                        ││
│  └────────────────────────┬────────────────────────────────────┘│
│                           │                                      │
│                           ▼ mutate                               │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   Mutated Variants                           ││
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐                        ││
│  │  │ Skill-1 │ │ Skill-2 │ │ Skill-3 │  (in sandboxes)        ││
│  │  └─────────┘ └─────────┘ └─────────┘                        ││
│  └────────────────────────┬────────────────────────────────────┘│
│                           │                                      │
│                           ▼ evaluate against anomaly corpus      │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                   Fitness Evaluation                         ││
│  │                                                              ││
│  │  For each (anomaly, expected_insight) in corpus:            ││
│  │    result = sandbox.run(skill.investigate(anomaly))         ││
│  │    score += match(result, expected_insight)                 ││
│  │                                                              ││
│  │  fitness = score / corpus_size                              ││
│  └────────────────────────┬────────────────────────────────────┘│
│                           │                                      │
│                           ▼ select, reproduce                    │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │             Next Generation of Skills                        ││
│  └─────────────────────────────────────────────────────────────┘│
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### Integration Code

```elixir
defmodule Evolution.SkillEvolver do
  @moduledoc """
  Evolve beamlens operator skills using sandbox.
  """

  def evolve_skill(skill_module, anomaly_corpus, config) do
    # Get original skill source
    source = get_skill_source(skill_module)

    # Create seed population
    population_id = "skill-evo-#{skill_module}"
    seed_ids = create_seed_population(source, config.population_size)
    Sandbox.PopulationRegistry.register(population_id, seed_ids, 0)

    # Evolution loop
    Enum.reduce_while(1..config.max_generations, nil, fn gen, _acc ->
      # Evaluate
      {:ok, members} = Sandbox.PopulationRegistry.get_members(population_id)

      results = Sandbox.batch_evaluate(members, fn sandbox_id ->
        evaluate_skill(sandbox_id, anomaly_corpus)
      end)

      # Check for convergence
      best_fitness = results |> Enum.max_by(fn {_, {:ok, f}} -> f end) |> elem(1) |> elem(1)

      if best_fitness >= config.target_fitness do
        {:halt, {:converged, gen, get_best_skill(members)}}
      else
        # Select and reproduce
        next_gen = evolve_generation(members, results, config)
        Sandbox.PopulationRegistry.advance_generation(population_id, next_gen)
        {:cont, nil}
      end
    end)
  end

  defp evaluate_skill(sandbox_id, corpus) do
    scores = Enum.map(corpus, fn {anomaly, expected} ->
      result = Sandbox.run(sandbox_id, fn ->
        module = get_sandbox_skill_module(sandbox_id)
        module.investigate(anomaly)
      end, timeout: 5_000)

      case result do
        {:ok, insight} -> if matches?(insight, expected), do: 1.0, else: 0.0
        {:error, _} -> 0.0
      end
    end)

    Enum.sum(scores) / length(scores)
  end
end
```

---

## Anti-Patterns

### Anti-Pattern 1: Sandbox as Database

**Wrong**: Storing long-term data in sandbox state.

```elixir
# DON'T do this
Sandbox.run(sandbox_id, fn ->
  GenServer.cast(DataStore, {:save, important_data})
end)
# Data lost when sandbox destroyed
```

**Right**: Use external storage, sandbox for computation only.

### Anti-Pattern 2: Cross-Sandbox Communication

**Wrong**: Sandboxes talking to each other.

```elixir
# DON'T do this
Sandbox.run(sandbox_a, fn ->
  Sandbox.run(sandbox_b, fn -> ... end)
end)
```

**Right**: Orchestrate from outside, sandboxes are isolated.

### Anti-Pattern 3: Long-Running Sandboxes

**Wrong**: Sandboxes that run for hours/days.

**Right**: Sandboxes are ephemeral. Create, evaluate, destroy. Keep state externally.

### Anti-Pattern 4: Trusting Evolved Code

**Wrong**: Giving evolved code access to production resources.

```elixir
# DON'T do this without safeguards
Sandbox.run(evolved_id, fn ->
  Repo.delete_all(Users)  # Evolved code shouldn't have DB access
end)
```

**Right**: Sandboxes get read-only access at most. Mock external services.

---

## Summary: What Goes Where

| Concern | Lives In | Not In Sandbox |
|---------|----------|----------------|
| Mutation | Evolution Engine | - |
| Selection | Evolution Engine | - |
| Population tracking | PopulationRegistry (in sandbox) | Evolution logic |
| Fitness computation | Sandbox.run() | Aggregation |
| Fitness storage | FitnessRecorder (in sandbox) | Historical analysis |
| Lineage | LineageTracker (in sandbox) | Visualization |
| Resource limits | ResourceEnforcer (in sandbox) | - |
| Code execution | Sandbox | - |
| LLM calls | External (CNS, etc.) | - |
| Persistent storage | External DB | - |
| Distributed coordination | Horde/pg | - |
| Monitoring | Beamlens (external) | - |

Sandbox is the **petri dish**. Everything else is the **lab**.
