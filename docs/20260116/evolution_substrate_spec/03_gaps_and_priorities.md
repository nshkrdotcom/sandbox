# Gaps and Priorities: Grounded Assessment

## Basis
This review reflects the current implementation in `lib/sandbox/*.ex`.
It is intentionally critical and focuses on what blocks evolution workloads today.

## Critical Gaps

### Gap 1: No execution entrypoint for evaluation
**Reality**: There is no `Sandbox.run/3` or equivalent. The public API provides
`get_sandbox_pid/1`, but there is no safe, bounded way to execute code inside a
sandbox and capture a result.

**Why it blocks evolution**: Fitness evaluation requires deterministic execution
with timeouts and crash capture. Without a formal entrypoint, evaluation is ad-hoc
and happens in the host VM context.

**Priority**: P0

---

### Gap 2: Isolation enforcement is mostly a no-op
**Reality**:
- `Sandbox.ResourceMonitor` and `Sandbox.SecurityController` are stubs.
- `Sandbox.ProcessIsolator` builds `spawn_opts` but uses `spawn/1`, so isolation
  flags are never applied.
- `max_heap_size` is set on the isolator process, not on the sandbox supervisor
  or its children.

**Why it blocks evolution**: Untrusted or buggy mutations can still exhaust the
host by spawning processes, leaking memory, or running forever.

**Priority**: P0

---

### Gap 3: Module loading semantics are inconsistent
**Reality**:
- `ModuleTransformer` rewrites source code and `IsolatedCompiler` compiles it.
- `VirtualCodeTable` stores BEAMs in ETS, but nothing loads modules from it.
- `setup_code_paths/2` is a no-op, so transformed BEAMs are not on the code path.
- `ModuleVersionManager` only loads binaries on hot swap; initial load does not
  call `:code.load_binary/3`.

**Why it blocks evolution**: There is no reliable path from transformed BEAMs to
executing code. Isolation is effectively just namespacing, not a separate code
server or loader.

**Priority**: P0

---

### Gap 4: Execution timeouts are validated but not enforced
**Reality**: `resource_limits` includes `:max_execution_time`, but nothing
uses it. `ProcessIsolator` can receive `{:resource_check}` but only logs usage.

**Why it blocks evolution**: Mutations can hang indefinitely, blocking fitness
loops and consuming resources.

**Priority**: P0

---

### Gap 5: Resource telemetry is not representative
**Reality**: `Sandbox.Manager` reports memory from the supervisor only and
approximates process counts by linked processes. There is no aggregation across
the sandbox process tree.

**Why it matters**: Fitness and safety signals derived from resource usage will
be misleading. Enforcement logic cannot be correct with this signal.

**Priority**: P1

---

## Important Gaps

### Gap 6: Batch operations are missing
Evolution workloads need to create, reload, evaluate, and destroy sandboxes in
parallel. The current API is strictly single-sandbox.

**Priority**: P1

---

### Gap 7: Sandbox execution context is undefined
There is no consistent way to route function calls or tool executions to the
sandbox process tree. `ProcessIsolator.send_message_to_sandbox/3` is generic but
no protocol exists for invoking code and returning results.

**Priority**: P1

---

### Gap 8: Automatic cleanup for stale sandboxes
`Manager.destroy_sandbox/1` cleans up, but there is no background garbage
collector for abandoned or crashed sandboxes during long-running evolution.

**Priority**: P2

---

## Out of Scope for Sandbox (Do Not Add Here)
These are evolution engine responsibilities and should remain external:
- Population registry and generation tracking
- Lineage graphs and ancestry queries
- Fitness history and selection strategy

Sandbox should provide safe execution and hot-reload primitives only.

---

## Priority Order

### Phase 1: Minimum Viable Evolution
1. Define and implement a `Sandbox.run/3` execution entrypoint with timeouts.
2. Fix `ProcessIsolator` to apply `spawn_opt` and enforce limits.
3. Define a real module-loading path (code server or custom loader).
4. Enforce execution timeouts in all evaluation paths.

### Phase 2: Safety and Throughput
1. Resource enforcement and accurate resource usage aggregation.
2. Batch operations for create/reload/destroy/evaluate.
3. Background cleanup for old or crashed sandboxes.

### Phase 3: Hardening
1. SecurityController enforcement.
2. Structured telemetry events for execution and enforcement outcomes.

---

## Bottom Line
Sandbox has strong scaffolding (lifecycle management, module version tracking,
state preservation). But the evolution-critical surface area is still missing:
execution entrypoint, enforcement, and a deterministic code-loading path. These
must land before any credible production evolution work can begin.
