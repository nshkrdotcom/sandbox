# Optimal Module Isolation Architecture for Apex Sandbox

## Executive Summary

The current Apex Sandbox architecture experiences module redefinition warnings when multiple sandboxes load modules with identical names. While functionally correct, this indicates a suboptimal design where sandboxes share the global BEAM code namespace. This document proposes an optimal architecture that provides true module isolation while maintaining backward compatibility and enabling a gradual migration path.

## Current Architecture Analysis

### Current Implementation

1. **Module Loading**: All sandboxes load modules into the global BEAM code space using `:code.load_binary/3`
2. **Namespace Sharing**: Module names are global across all sandboxes
3. **Version Tracking**: `ModuleVersionManager` tracks versions but cannot prevent namespace conflicts
4. **File Isolation**: Each sandbox copies source to a unique directory (`/tmp/sandbox_<id>/`)

### Limitations

1. **Module Redefinition Warnings**: Unavoidable when loading same-named modules
2. **No True Isolation**: One sandbox can affect another through module redefinition
3. **Limited Concurrency**: Module loading must be serialized to avoid race conditions
4. **Security Concerns**: Sandboxes can potentially interfere with each other's code
5. **Testing Complexity**: Parallel tests generate numerous warnings, complicating CI/CD

## Proposed Optimal Architecture

### Design Principles

1. **True Module Isolation**: Each sandbox has its own module namespace
2. **Zero Global Pollution**: Sandbox modules never enter the global code space
3. **Concurrent Safety**: Multiple sandboxes can load same-named modules without conflict
4. **Backward Compatibility**: Existing sandbox behavior preserved with opt-in migration
5. **Performance**: Minimal overhead compared to current implementation

### Technical Architecture

#### Option 1: Process-Based Module Isolation (Recommended)

This approach leverages Erlang's process isolation to create separate code spaces.

```elixir
defmodule Sandbox.IsolatedRuntime do
  @moduledoc """
  Provides true module isolation by running sandbox code in isolated processes
  with custom code loading semantics.
  """

  defstruct [
    :id,
    :runtime_pid,
    :code_server_pid,
    :loaded_modules,
    :module_cache,
    :parent_sandbox
  ]

  @doc """
  Starts an isolated runtime for a sandbox.
  """
  def start_link(sandbox_id, opts \\ []) do
    GenServer.start_link(__MODULE__, {sandbox_id, opts}, name: via_tuple(sandbox_id))
  end

  @impl true
  def init({sandbox_id, opts}) do
    # Start a dedicated code server process for this sandbox
    {:ok, code_server_pid} = Sandbox.CodeServer.start_link(sandbox_id)
    
    # Start the runtime process with restricted code loading
    {:ok, runtime_pid} = start_isolated_runtime(sandbox_id, code_server_pid, opts)
    
    state = %__MODULE__{
      id: sandbox_id,
      runtime_pid: runtime_pid,
      code_server_pid: code_server_pid,
      loaded_modules: %{},
      module_cache: %{},
      parent_sandbox: self()
    }
    
    {:ok, state}
  end

  defp start_isolated_runtime(sandbox_id, code_server_pid, opts) do
    Task.start_link(fn ->
      # Override code loading functions in this process
      Process.put(:"$sandbox_code_server", code_server_pid)
      Process.put(:"$sandbox_id", sandbox_id)
      
      # Install custom code loader
      install_sandbox_code_loader()
      
      # Keep process alive
      receive do
        :never -> :ok
      end
    end)
  end
end
```

#### Option 2: Module Name Transformation

Transform module names to include sandbox context:

```elixir
defmodule Sandbox.ModuleTransformer do
  @moduledoc """
  Transforms module names and references to provide namespace isolation.
  """

  @doc """
  Transforms source code to prefix all module names with sandbox ID.
  
  Example:
    Input:  defmodule MyModule do ... end
    Output: defmodule Sandbox_abc123_MyModule do ... end
  """
  def transform_source(source_code, sandbox_id) do
    source_code
    |> Code.string_to_quoted!()
    |> Macro.prewalk(&transform_ast(&1, sandbox_id))
    |> Macro.to_string()
  end

  defp transform_ast({:defmodule, meta, [{:__aliases__, _, module_parts}, body]}, sandbox_id) do
    # Prefix module name with sandbox ID
    prefixed_parts = [:"Elixir", :"Sandbox_#{sandbox_id}" | module_parts]
    {:defmodule, meta, [{:__aliases__, [], prefixed_parts}, body]}
  end

  defp transform_ast({:__aliases__, meta, module_parts}, sandbox_id) when module_parts != [] do
    # Transform module references
    if external_module?(module_parts) do
      {:__aliases__, meta, module_parts}
    else
      prefixed_parts = [:"Sandbox_#{sandbox_id}" | module_parts]
      {:__aliases__, meta, prefixed_parts}
    end
  end

  defp transform_ast(ast, _sandbox_id), do: ast
end
```

#### Option 3: ETS-Based Virtual Code Table

Implement a virtual code table using ETS:

```elixir
defmodule Sandbox.VirtualCodeTable do
  @moduledoc """
  Provides virtual code tables for sandbox isolation using ETS.
  """

  def create_table(sandbox_id) do
    table_name = :"sandbox_code_#{sandbox_id}"
    :ets.new(table_name, [:named_table, :set, :public, {:read_concurrency, true}])
  end

  def load_module(sandbox_id, module, beam_data) do
    table_name = :"sandbox_code_#{sandbox_id}"
    
    # Store module data in ETS instead of global code space
    :ets.insert(table_name, {module, %{
      beam_data: beam_data,
      loaded_at: System.monotonic_time(),
      attributes: extract_attributes(beam_data),
      exports: extract_exports(beam_data)
    }})
    
    :ok
  end

  def fetch_module(sandbox_id, module) do
    table_name = :"sandbox_code_#{sandbox_id}"
    
    case :ets.lookup(table_name, module) do
      [{^module, module_info}] -> {:ok, module_info}
      [] -> {:error, :not_loaded}
    end
  end
end
```

### Recommended Implementation: Hybrid Approach

The optimal solution combines the best aspects of each option:

```elixir
defmodule Sandbox.OptimalIsolation do
  @moduledoc """
  Provides optimal module isolation using a hybrid approach:
  1. Module name transformation for compile-time isolation
  2. Process-based runtime isolation for execution
  3. ETS-based code tables for efficient lookup
  """

  defmodule Config do
    defstruct [
      isolation_mode: :hybrid,  # :hybrid | :transform | :process | :legacy
      transform_modules: true,
      use_virtual_code_table: true,
      use_process_isolation: true,
      compatibility_mode: false
    ]
  end

  def compile_and_load(sandbox_id, source_path, config \\ %Config{}) do
    with {:ok, source_files} <- discover_source_files(source_path),
         {:ok, transformed} <- transform_if_enabled(source_files, sandbox_id, config),
         {:ok, compiled} <- compile_isolated(transformed, sandbox_id),
         {:ok, loaded} <- load_isolated(compiled, sandbox_id, config) do
      {:ok, loaded}
    end
  end

  defp transform_if_enabled(source_files, sandbox_id, %Config{transform_modules: true}) do
    Enum.map(source_files, fn {path, content} ->
      transformed = Sandbox.ModuleTransformer.transform_source(content, sandbox_id)
      {path, transformed}
    end)
    |> then(&{:ok, &1})
  end

  defp load_isolated(compiled_modules, sandbox_id, config) do
    case config.isolation_mode do
      :hybrid ->
        # Use virtual code table for lookup, process isolation for execution
        load_hybrid(compiled_modules, sandbox_id)
      
      :transform ->
        # Load transformed modules into global space (safe due to unique names)
        load_transformed(compiled_modules)
      
      :process ->
        # Load into isolated process only
        load_process_isolated(compiled_modules, sandbox_id)
      
      :legacy ->
        # Current behavior for backward compatibility
        load_legacy(compiled_modules)
    end
  end
end
```

## Migration Strategy

### Phase 1: Infrastructure (Weeks 1-2)
1. Implement `Sandbox.ModuleTransformer`
2. Implement `Sandbox.VirtualCodeTable`
3. Add configuration system for isolation modes
4. Create compatibility layer for existing code

### Phase 2: Integration (Weeks 3-4)
1. Update `IsolatedCompiler` to support transformation
2. Modify `Manager` to use new isolation features
3. Update `ModuleVersionManager` for virtual code tables
4. Add metrics and monitoring

### Phase 3: Migration (Weeks 5-6)
1. Add feature flags for gradual rollout
2. Migrate test suites to use new isolation
3. Update documentation and examples
4. Performance testing and optimization

### Phase 4: Completion (Week 7)
1. Enable by default for new sandboxes
2. Provide migration tools for existing sandboxes
3. Deprecation notices for legacy mode
4. Final documentation updates

## Performance Considerations

### Memory Overhead
- **Current**: ~0 bytes per sandbox (shared global space)
- **Transform**: ~5-10% increase due to longer module names
- **Process**: ~2MB per sandbox for isolated process
- **Hybrid**: ~1MB per sandbox for virtual tables + process

### CPU Overhead
- **Current**: O(1) module lookup
- **Transform**: O(1) module lookup (same as current)
- **Process**: O(n) for cross-process calls
- **Hybrid**: O(1) for lookups, O(1) for local calls

### Recommended Configuration
```elixir
config :sandbox, :isolation,
  mode: :hybrid,
  transform_modules: true,
  use_virtual_code_table: true,
  use_process_isolation: false,  # Only for untrusted code
  max_modules_per_sandbox: 1000,
  cache_compiled_modules: true
```

## Security Benefits

1. **Complete Isolation**: Sandboxes cannot interfere with each other
2. **Resource Limits**: Per-sandbox memory and CPU limits
3. **Code Inspection**: Transform phase allows security scanning
4. **Audit Trail**: All module operations logged per sandbox

## Backward Compatibility

### Compatibility Layer
```elixir
defmodule Sandbox.Compatibility do
  @doc """
  Provides backward-compatible module loading for existing code.
  """
  def load_module(module, beam_data, opts \\ []) do
    if legacy_mode?(opts) do
      # Current behavior
      :code.load_binary(module, '', beam_data)
    else
      # New isolation behavior
      sandbox_id = Keyword.fetch!(opts, :sandbox_id)
      Sandbox.OptimalIsolation.load_module(sandbox_id, module, beam_data)
    end
  end
end
```

### Migration Checklist
- [ ] Update all `Code.ensure_loaded/1` calls to use sandbox context
- [ ] Replace `:code.load_binary/3` with isolated loader
- [ ] Update module discovery to handle transformed names
- [ ] Modify hot-reload to support new architecture
- [ ] Update tests to expect no warnings

## Testing Strategy

### Unit Tests
```elixir
defmodule Sandbox.IsolationTest do
  use ExUnit.Case

  test "multiple sandboxes can load same module name" do
    {:ok, _} = Sandbox.OptimalIsolation.load_module("sandbox1", MyModule, beam1)
    {:ok, _} = Sandbox.OptimalIsolation.load_module("sandbox2", MyModule, beam2)
    
    # No warnings, different module instances
    assert Sandbox.VirtualCodeTable.fetch_module("sandbox1", MyModule) !=
           Sandbox.VirtualCodeTable.fetch_module("sandbox2", MyModule)
  end
end
```

### Integration Tests
- Parallel sandbox creation
- Cross-sandbox isolation verification
- Performance benchmarks
- Memory usage monitoring

## Conclusion

The proposed architecture provides true module isolation while maintaining the flexibility and power of the current system. The hybrid approach offers the best balance of performance, security, and compatibility. The phased migration strategy ensures a smooth transition with minimal disruption to existing users.

Key benefits:
1. **No module redefinition warnings**
2. **True sandbox isolation**
3. **Better security and stability**
4. **Improved testing experience**
5. **Foundation for future features** (e.g., sandbox suspension, migration, versioning)

The investment in this architecture will pay dividends as the platform scales and security requirements increase.