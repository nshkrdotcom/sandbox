# Sandbox as Evolution Substrate: Technical Specification

## Purpose

This document suite specifies how `sandbox` transforms from an isolated code execution environment into the **runtime substrate for self-building BEAM systems**.

## The Core Thesis

From the vision documents:

> "Your `sandbox` library isn't a plugin system. It's a **Petri dish for code evolution**."

Sandbox provides the foundational capability that no other mainstream runtime offers: **hot-reload code into supervised, isolated processes without restart**. This is the primitive on which genetic programming of live systems becomes possible.

## What "Evolution Substrate" Means

An evolution substrate must:

1. **Spawn individuals** - Create isolated execution contexts for code variants
2. **Hot-load genomes** - Inject mutated code without restart
3. **Evaluate fitness** - Run tests/benchmarks safely
4. **Contain failures** - One bad mutation cannot crash the host
5. **Track lineage** - Know which version came from where
6. **Garbage collect** - Clean up dead individuals efficiently
7. **Scale horizontally** - Distribute populations across BEAM nodes

Sandbox already does 1, 2, and 5. The rest needs implementation or hardening.

## Document Structure

| Document | Purpose |
|----------|---------|
| [01_current_state](01_current_state.md) | Honest assessment of what sandbox does today |
| [02_architecture](02_architecture.md) | Target architecture for evolution workloads |
| [03_gaps_and_priorities](03_gaps_and_priorities.md) | What's missing and build order |
| [04_api_specification](04_api_specification.md) | Proposed API additions/changes |
| [05_integration_patterns](05_integration_patterns.md) | How sandbox fits the broader ecosystem |

## Key Constraints

### What We Cannot Change

1. **BEAM's shared code space** - All processes share one code loader
2. **Process isolation limits** - Processes isolate state, not CPU/memory
3. **No OS-level sandboxing** - BEAM doesn't have seccomp/containers
4. **Hot-reload semantics** - Old code stays until no processes reference it

### What We Can Build Around

1. **Module namespacing** - Prefix modules to avoid collisions (already done)
2. **Supervision trees** - Isolate failure domains
3. **Resource monitoring** - Track usage even if we can't hard-limit
4. **Version management** - Roll back bad mutations
5. **ETS isolation** - Virtual code tables per sandbox

## Success Criteria

Sandbox is ready as evolution substrate when:

1. **Proof of concept passes**: A genetic algorithm evolves a trivial function using sandbox as runtime
2. **Population scale**: 100+ concurrent sandboxes without degradation
3. **Failure containment**: Bad mutations don't escape their sandbox
4. **Clean lifecycle**: Dead individuals are properly garbage collected
5. **Observable**: Telemetry shows population health and fitness distribution

## Non-Goals (For Now)

- **True OS-level isolation** - Use containers/firecracker if you need this
- **Multi-language support** - Elixir only (tree-sitter integration is future Ferrousbridge work)
- **Distributed coordination** - libcluster/horde handle this; sandbox is local
- **Persistence** - State snapshots to disk are out of scope (use external storage)

## Related Documents

- `~/p/g/research/20260109/self_building_beam_vision/` - The vision documents
- `~/p/g/n/beamlens/` - Potential fitness signal source (monitoring)
- `~/p/g/n/sandbox/` - The implementation

---

*Created 2026-01-16*
