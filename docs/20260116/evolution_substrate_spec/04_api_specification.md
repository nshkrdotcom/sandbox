# API Specification: Minimal Evolution Substrate

## Principles
- Sandbox is a substrate, not the evolution engine.
- The public API should expose safe execution and hot-reload primitives only.
- Population management, lineage, and fitness remain external.

---

## Existing Public API (As-Is)
The current surface area is centered on sandbox lifecycle and module hot reload:
- `Sandbox.create_sandbox/3`
- `Sandbox.destroy_sandbox/1`
- `Sandbox.restart_sandbox/1`
- `Sandbox.hot_reload/3`
- `Sandbox.get_sandbox_info/1`
- `Sandbox.list_sandboxes/0`
- `Sandbox.get_sandbox_pid/1`
- `Sandbox.compile_sandbox/2`
- `Sandbox.compile_file/2`

These remain unchanged.

---

## Required Additions

### 1. Execution entrypoint
A deterministic, timeout-bound execution entrypoint is required for fitness
computation and testing.

```elixir
Sandbox.run(sandbox_id, fun, opts \\ [])
```

**Semantics**:
- Executes `fun` inside the sandbox execution context.
- Enforces `:timeout` (default 30_000 ms).
- Captures crashes and returns structured errors.

**Returns**:
- `{:ok, result}`
- `{:error, :timeout}`
- `{:error, {:crashed, reason}}`
- `{:error, :sandbox_not_found}`

**Notes**:
- This must execute in the sandbox process tree, not on the host scheduler.
- The current API only exposes `get_sandbox_pid/1`; that is insufficient.

---

### 2. Source-level hot reload
Mutation engines generate source, not BEAM. Provide a source-based entrypoint.

```elixir
Sandbox.hot_reload_source(sandbox_id, source_code, opts \\ [])
```

**Semantics**:
- Applies module transformation for sandbox namespacing.
- Compiles in isolation.
- Loads compiled modules into the runtime (not just ETS).
- Updates ModuleVersionManager and VirtualCodeTable metadata.

**Returns**:
- `{:ok, :hot_reloaded}`
- `{:error, {:parse_failed, reason}}`
- `{:error, {:compilation_failed, reason}}`

---

### 3. Batch operations
Evolution loops are parallel. Provide batched operations with bounded
concurrency.

```elixir
Sandbox.batch_create(configs, opts \\ [])
Sandbox.batch_destroy(sandbox_ids, opts \\ [])
Sandbox.batch_run(sandbox_ids, fun, opts \\ [])
Sandbox.batch_hot_reload(sandbox_ids, beam_or_source, opts \\ [])
```

**Semantics**:
- Uses `Task.async_stream/3` internally with configurable concurrency.
- Returns per-sandbox results; failures do not abort the batch.

---

### 4. Resource usage query (aggregated)
Evolution needs accurate signals.

```elixir
Sandbox.resource_usage(sandbox_id)
```

**Semantics**:
- Aggregates memory, process count, message queue length, and uptime across the
  sandbox process tree (not just the supervisor).
- Returns `{:error, :not_found}` if the sandbox is missing.

---

## Nice-to-Have Additions

### 5. Limit configuration updates
Allow adjusting limits after creation when running experiments.

```elixir
Sandbox.update_limits(sandbox_id, limits)
```

This should validate and apply limits to the sandbox context, not just store
values in config.

---

## Explicit Non-Goals (External System Responsibilities)
These features should not be added to sandbox:
- Population registry
- Lineage tracking
- Fitness history or selection
- Model mutation logic

Sandbox should remain a safe execution substrate only.

---

## Telemetry (Minimal Set)
Add events that correspond to the new execution surface:
- `[:sandbox, :run, :start | :stop | :exception]`
- `[:sandbox, :batch, :start | :stop]`
- `[:sandbox, :resource, :sampled]`

Keep metadata lean (sandbox_id, duration, result).

---

## Error Conventions
Use stable atoms for common failures:
- `:sandbox_not_found`
- `:timeout`
- `{:crashed, reason}`
- `{:compilation_failed, reason}`
- `{:parse_failed, reason}`

---

## Summary
This API spec intentionally avoids evolution-engine concerns and focuses on the
minimum surface required for a safe, testable, and parallel execution substrate.
