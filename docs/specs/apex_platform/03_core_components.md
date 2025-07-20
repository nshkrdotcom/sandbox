# Apex Platform - Core Components

## Overview

This document provides detailed specifications for the core components that form the foundation of the Apex Platform. These components are shared across all operational modes and provide the fundamental services required for both secure isolation and development features.

## Module Manager

### Purpose
Manages module loading, transformation, versioning, and lifecycle across all operational modes.

### Specification

```elixir
defmodule Apex.Core.ModuleManager do
  @moduledoc """
  Unified module management system supporting transformation, versioning,
  and hot-swapping across isolation and development modes.
  """
  
  use GenServer
  require Logger
  
  @type module_id :: {sandbox_id :: String.t(), module_name :: module()}
  @type load_options :: [
    mode: :isolation | :development | :hybrid,
    transform: boolean(),
    version: String.t(),
    namespace: String.t(),
    security_scan: boolean(),
    metadata: map()
  ]
  
  @type module_info :: %{
    id: module_id(),
    original_name: module(),
    transformed_name: module() | nil,
    bytecode: binary(),
    source: String.t() | nil,
    version: String.t(),
    checksum: String.t(),
    dependencies: [module()],
    exports: [{atom(), arity()}],
    attributes: keyword(),
    loaded_at: DateTime.t(),
    access_count: non_neg_integer()
  }
  
  defstruct [
    modules: %{},          # module_id => module_info
    versions: %{},         # module_id => [version]
    dependencies: %{},     # module => [dependent_modules]
    transformers: [],      # Active transformers
    mode_config: %{},      # Mode-specific configuration
    metrics: %{}           # Performance metrics
  ]
  
  # Client API
  
  @spec load_module(String.t(), module(), binary(), load_options()) :: 
    {:ok, module()} | {:error, term()}
  def load_module(sandbox_id, module_name, beam_code, opts \\ []) do
    GenServer.call(__MODULE__, {:load_module, sandbox_id, module_name, beam_code, opts})
  end
  
  @spec get_module(String.t(), module()) :: {:ok, module_info()} | {:error, :not_found}
  def get_module(sandbox_id, module_name) do
    GenServer.call(__MODULE__, {:get_module, sandbox_id, module_name})
  end
  
  @spec hot_swap(String.t(), module(), binary()) :: :ok | {:error, term()}
  def hot_swap(sandbox_id, module_name, new_beam_code) do
    GenServer.call(__MODULE__, {:hot_swap, sandbox_id, module_name, new_beam_code})
  end
  
  @spec list_modules(String.t()) :: [module_info()]
  def list_modules(sandbox_id) do
    GenServer.call(__MODULE__, {:list_modules, sandbox_id})
  end
  
  # Server Implementation
  
  def handle_call({:load_module, sandbox_id, module_name, beam_code, opts}, _from, state) do
    mode = Keyword.get(opts, :mode, :isolation)
    
    with {:ok, verified_code} <- verify_bytecode(beam_code),
         {:ok, scanned_code} <- maybe_security_scan(verified_code, mode, opts),
         {:ok, transformed} <- maybe_transform(sandbox_id, module_name, scanned_code, mode, opts),
         {:ok, module_info} <- create_module_info(sandbox_id, module_name, transformed, opts),
         :ok <- load_into_vm(module_info, mode) do
      
      new_state = store_module(state, module_info)
      {:reply, {:ok, module_info.transformed_name || module_name}, new_state}
    else
      error -> {:reply, error, state}
    end
  end
  
  defp maybe_transform(sandbox_id, module_name, beam_code, :isolation, opts) do
    namespace = Keyword.get(opts, :namespace, sandbox_id)
    transformer = get_transformer(opts)
    transformer.transform(module_name, beam_code, namespace: namespace)
  end
  
  defp maybe_transform(_sandbox_id, module_name, beam_code, :development, _opts) do
    # No transformation in development mode
    {:ok, {module_name, beam_code}}
  end
  
  defp maybe_transform(sandbox_id, module_name, beam_code, :hybrid, opts) do
    if Keyword.get(opts, :transform, false) do
      maybe_transform(sandbox_id, module_name, beam_code, :isolation, opts)
    else
      {:ok, {module_name, beam_code}}
    end
  end
end
```

### Module Transformer

```elixir
defmodule Apex.Core.ModuleTransformer do
  @moduledoc """
  Transforms module names and references for isolation mode.
  """
  
  @type transform_opts :: [
    namespace: String.t(),
    strategy: :prefix | :suffix | :hash,
    deep_transform: boolean()
  ]
  
  @spec transform(module(), binary(), transform_opts()) :: 
    {:ok, {module(), binary()}} | {:error, term()}
  def transform(module_name, beam_code, opts \\ []) do
    namespace = Keyword.get(opts, :namespace)
    strategy = Keyword.get(opts, :strategy, :prefix)
    
    with {:ok, forms} <- beam_to_forms(beam_code),
         transformed_forms <- transform_forms(forms, module_name, namespace, strategy),
         {:ok, new_beam} <- forms_to_beam(transformed_forms) do
      
      new_name = build_module_name(module_name, namespace, strategy)
      {:ok, {new_name, new_beam}}
    end
  end
  
  defp build_module_name(original, namespace, :prefix) do
    Module.concat([namespace, original])
  end
  
  defp build_module_name(original, namespace, :suffix) do
    Module.concat([original, namespace])
  end
  
  defp build_module_name(original, namespace, :hash) do
    hash = :crypto.hash(:sha256, "#{original}#{namespace}")
           |> Base.encode16(case: :lower)
           |> binary_part(0, 8)
    Module.concat(["Apex", hash, original])
  end
end
```

## State Manager

### Purpose
Manages state synchronization, preservation, and manipulation across sandbox boundaries.

### Specification

```elixir
defmodule Apex.Core.StateManager do
  @moduledoc """
  Unified state management for synchronization, preservation, and manipulation.
  """
  
  use GenServer
  
  @type state_id :: String.t()
  @type sync_mode :: :push | :pull | :bidirectional
  @type sync_strategy :: :eager | :lazy | {:periodic, pos_integer()} | :manual
  
  @type state_bridge :: %{
    id: state_id(),
    source: pid() | node() | module(),
    target: pid() | node() | module(),
    mode: sync_mode(),
    strategy: sync_strategy(),
    filters: [filter()],
    transformers: [transformer()],
    status: :active | :paused | :error,
    stats: bridge_stats()
  }
  
  @type filter :: (term() -> boolean()) | {module(), atom(), [term()]}
  @type transformer :: (term() -> term()) | {module(), atom(), [term()]}
  
  @type state_snapshot :: %{
    id: String.t(),
    timestamp: DateTime.t(),
    source: term(),
    data: term(),
    metadata: map(),
    checksum: String.t()
  }
  
  # Client API
  
  @spec create_bridge(term(), term(), keyword()) :: {:ok, state_id()} | {:error, term()}
  def create_bridge(source, target, opts \\ []) do
    GenServer.call(__MODULE__, {:create_bridge, source, target, opts})
  end
  
  @spec sync_now(state_id()) :: {:ok, sync_stats()} | {:error, term()}
  def sync_now(bridge_id) do
    GenServer.call(__MODULE__, {:sync_now, bridge_id})
  end
  
  @spec capture_snapshot(term(), keyword()) :: {:ok, state_snapshot()} | {:error, term()}
  def capture_snapshot(source, opts \\ []) do
    GenServer.call(__MODULE__, {:capture_snapshot, source, opts})
  end
  
  @spec restore_snapshot(term(), state_snapshot()) :: :ok | {:error, term()}
  def restore_snapshot(target, snapshot) do
    GenServer.call(__MODULE__, {:restore_snapshot, target, snapshot})
  end
  
  @spec manipulate_state(pid(), function()) :: {:ok, term()} | {:error, term()}
  def manipulate_state(process, fun) when is_pid(process) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:manipulate_state, process, fun})
  end
  
  # Server Implementation
  
  def handle_call({:create_bridge, source, target, opts}, _from, state) do
    bridge = %{
      id: generate_id(),
      source: source,
      target: target,
      mode: Keyword.get(opts, :mode, :push),
      strategy: Keyword.get(opts, :strategy, :lazy),
      filters: compile_filters(Keyword.get(opts, :filters, [])),
      transformers: compile_transformers(Keyword.get(opts, :transformers, [])),
      status: :active,
      stats: %{syncs: 0, errors: 0, last_sync: nil}
    }
    
    # Start sync process if needed
    maybe_start_sync_process(bridge)
    
    new_state = Map.put(state.bridges, bridge.id, bridge)
    {:reply, {:ok, bridge.id}, %{state | bridges: new_state}}
  end
  
  def handle_call({:manipulate_state, process, fun}, _from, state) do
    # Check permissions based on mode
    with :ok <- check_manipulation_permission(process, state.mode),
         {:ok, current_state} <- get_process_state(process),
         {:ok, new_state} <- apply_manipulation(current_state, fun),
         :ok <- validate_new_state(new_state, process),
         {:ok, backup} <- create_state_backup(process, current_state),
         :ok <- set_process_state(process, new_state) do
      
      {:reply, {:ok, %{backup: backup, new_state: new_state}}, state}
    else
      error -> {:reply, error, state}
    end
  end
end
```

### State Synchronizer

```elixir
defmodule Apex.Core.StateSynchronizer do
  @moduledoc """
  Handles the actual synchronization of state between sources and targets.
  """
  
  use GenServer
  
  def sync(bridge) do
    case bridge.mode do
      :push -> push_sync(bridge)
      :pull -> pull_sync(bridge)
      :bidirectional -> bidirectional_sync(bridge)
    end
  end
  
  defp push_sync(bridge) do
    with {:ok, source_state} <- collect_state(bridge.source),
         filtered_state <- apply_filters(source_state, bridge.filters),
         transformed_state <- apply_transformers(filtered_state, bridge.transformers),
         :ok <- apply_state(bridge.target, transformed_state) do
      
      {:ok, %{items: map_size(transformed_state), direction: :push}}
    end
  end
  
  defp collect_state(source) when is_pid(source) do
    case :sys.get_state(source, 5000) do
      state -> {:ok, state}
    catch
      :exit, _ -> {:error, :process_not_responding}
    end
  end
  
  defp collect_state(source) when is_atom(source) do
    # Collect from ETS tables associated with module
    tables = :ets.all()
    |> Enum.filter(&match_module_tables(&1, source))
    |> Enum.map(&read_table/1)
    |> Enum.into(%{})
    
    {:ok, tables}
  end
end
```

## Process Manager

### Purpose
Manages process lifecycle, isolation, monitoring, and communication across modes.

### Specification

```elixir
defmodule Apex.Core.ProcessManager do
  @moduledoc """
  Unified process management with mode-aware isolation and monitoring.
  """
  
  use GenServer
  
  @type process_id :: String.t()
  @type isolation_level :: :none | :partial | :full
  @type process_opts :: [
    mode: :isolation | :development | :hybrid,
    isolation: isolation_level(),
    monitors: [monitor_type()],
    limits: resource_limits(),
    metadata: map()
  ]
  
  @type monitor_type :: :cpu | :memory | :messages | :calls | :errors
  @type resource_limits :: %{
    max_heap_size: pos_integer(),
    max_reductions: pos_integer(),
    max_message_queue: pos_integer()
  }
  
  @type managed_process :: %{
    id: process_id(),
    pid: pid(),
    module: module(),
    function: atom(),
    args: list(),
    isolation_level: isolation_level(),
    monitors: [monitor_ref()],
    limits: resource_limits(),
    stats: process_stats(),
    created_at: DateTime.t()
  }
  
  # Client API
  
  @spec spawn_isolated(module(), atom(), list(), process_opts()) :: 
    {:ok, process_id()} | {:error, term()}
  def spawn_isolated(module, function, args, opts \\ []) do
    GenServer.call(__MODULE__, {:spawn_isolated, module, function, args, opts})
  end
  
  @spec monitor_process(pid() | process_id(), [monitor_type()]) :: 
    {:ok, monitor_ref()} | {:error, term()}
  def monitor_process(process, monitor_types) do
    GenServer.call(__MODULE__, {:monitor_process, process, monitor_types})
  end
  
  @spec set_limits(process_id(), resource_limits()) :: :ok | {:error, term()}
  def set_limits(process_id, limits) do
    GenServer.call(__MODULE__, {:set_limits, process_id, limits})
  end
  
  @spec get_stats(process_id()) :: {:ok, process_stats()} | {:error, term()}
  def get_stats(process_id) do
    GenServer.call(__MODULE__, {:get_stats, process_id})
  end
  
  # Server Implementation
  
  def handle_call({:spawn_isolated, module, function, args, opts}, _from, state) do
    mode = Keyword.get(opts, :mode, :isolation)
    isolation = determine_isolation_level(mode, opts)
    
    spawn_fun = case isolation do
      :none -> &spawn_direct/3
      :partial -> &spawn_with_monitors/3
      :full -> &spawn_fully_isolated/3
    end
    
    case spawn_fun.(module, function, args) do
      {:ok, pid} ->
        process_info = build_process_info(pid, module, function, args, opts)
        new_state = store_process(state, process_info)
        {:reply, {:ok, process_info.id}, new_state}
        
      error ->
        {:reply, error, state}
    end
  end
  
  defp spawn_fully_isolated(module, function, args) do
    # Create isolated process with restricted capabilities
    parent = self()
    
    pid = spawn(fn ->
      # Remove dangerous capabilities
      Process.flag(:trap_exit, true)
      Process.put(:"$apex_isolated", true)
      
      # Set up restrictions
      :erlang.process_flag(:max_heap_size, %{
        size: 50_000_000,
        kill: true,
        error_logger: true
      })
      
      # Execute function with error handling
      try do
        result = apply(module, function, args)
        send(parent, {:result, self(), result})
      catch
        kind, reason ->
          send(parent, {:error, self(), {kind, reason, __STACKTRACE__}})
      end
    end)
    
    {:ok, pid}
  end
end
```

### Process Monitor

```elixir
defmodule Apex.Core.ProcessMonitor do
  @moduledoc """
  Real-time process monitoring with configurable metrics collection.
  """
  
  use GenServer
  
  @type monitor_config :: %{
    process: pid(),
    types: [monitor_type()],
    interval: pos_integer(),
    thresholds: map(),
    actions: map()
  }
  
  def start_monitoring(process, types, opts \\ []) do
    config = %{
      process: process,
      types: types,
      interval: Keyword.get(opts, :interval, 1000),
      thresholds: Keyword.get(opts, :thresholds, %{}),
      actions: Keyword.get(opts, :actions, %{})
    }
    
    GenServer.start_link(__MODULE__, config)
  end
  
  def init(config) do
    # Start monitoring
    schedule_next_check(config.interval)
    Process.monitor(config.process)
    
    {:ok, %{config: config, metrics: %{}, alerts: []}}
  end
  
  def handle_info(:check_metrics, state) do
    metrics = collect_metrics(state.config.process, state.config.types)
    alerts = check_thresholds(metrics, state.config.thresholds)
    
    # Take actions if needed
    Enum.each(alerts, fn alert ->
      action = Map.get(state.config.actions, alert.type, :log)
      execute_action(action, alert)
    end)
    
    # Store metrics
    new_state = %{state | metrics: metrics, alerts: alerts}
    
    # Schedule next check
    schedule_next_check(state.config.interval)
    
    {:noreply, new_state}
  end
  
  defp collect_metrics(pid, types) do
    Enum.reduce(types, %{}, fn type, acc ->
      Map.put(acc, type, collect_metric(pid, type))
    end)
  end
  
  defp collect_metric(pid, :memory) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      nil -> nil
    end
  end
  
  defp collect_metric(pid, :messages) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, count} -> count
      nil -> nil
    end
  end
end
```

## Resource Manager

### Purpose
Manages and enforces resource limits across all sandboxes and modes.

### Specification

```elixir
defmodule Apex.Core.ResourceManager do
  @moduledoc """
  Centralized resource management with mode-aware limits and monitoring.
  """
  
  use GenServer
  
  @type resource_type :: :memory | :cpu | :processes | :ets_tables | :ports
  @type resource_allocation :: %{
    sandbox_id: String.t(),
    allocations: %{resource_type() => limit()},
    usage: %{resource_type() => current()},
    reserved: %{resource_type() => reserved()}
  }
  
  @type limit :: pos_integer() | :unlimited
  @type current :: non_neg_integer()
  @type reserved :: non_neg_integer()
  
  defstruct [
    allocations: %{},      # sandbox_id => resource_allocation
    global_limits: %{},    # resource_type => limit
    mode_defaults: %{},    # mode => default_limits
    policies: [],          # Resource policies
    monitors: %{}          # Active monitors
  ]
  
  # Client API
  
  @spec allocate(String.t(), map(), keyword()) :: {:ok, resource_allocation()} | {:error, term()}
  def allocate(sandbox_id, requested_resources, opts \\ []) do
    GenServer.call(__MODULE__, {:allocate, sandbox_id, requested_resources, opts})
  end
  
  @spec deallocate(String.t()) :: :ok
  def deallocate(sandbox_id) do
    GenServer.call(__MODULE__, {:deallocate, sandbox_id})
  end
  
  @spec check_limit(String.t(), resource_type(), non_neg_integer()) :: :ok | {:error, :limit_exceeded}
  def check_limit(sandbox_id, resource_type, amount) do
    GenServer.call(__MODULE__, {:check_limit, sandbox_id, resource_type, amount})
  end
  
  @spec get_usage(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_usage(sandbox_id) do
    GenServer.call(__MODULE__, {:get_usage, sandbox_id})
  end
  
  # Mode-specific defaults
  
  def default_limits(:isolation) do
    %{
      memory: 100_000_000,      # 100MB
      cpu: 50,                  # 50%
      processes: 1_000,         
      ets_tables: 50,
      ports: 0                  # No ports in isolation
    }
  end
  
  def default_limits(:development) do
    %{
      memory: :unlimited,
      cpu: :unlimited,
      processes: :unlimited,
      ets_tables: :unlimited,
      ports: :unlimited
    }
  end
  
  def default_limits(:hybrid) do
    %{
      memory: 500_000_000,      # 500MB
      cpu: 80,                  # 80%
      processes: 10_000,
      ets_tables: 500,
      ports: 10
    }
  end
end
```

## Storage Layer

### Purpose
Provides multi-tier storage for different data types and access patterns.

### Specification

```elixir
defmodule Apex.Core.Storage do
  @moduledoc """
  Unified storage layer with hot, warm, and cold tiers.
  """
  
  @type storage_key :: term()
  @type storage_value :: term()
  @type storage_tier :: :hot | :warm | :cold
  @type storage_opts :: [
    tier: storage_tier(),
    ttl: pos_integer() | :infinity,
    compression: boolean(),
    encryption: boolean()
  ]
  
  # Storage behaviour
  @callback put(storage_key(), storage_value(), storage_opts()) :: :ok | {:error, term()}
  @callback get(storage_key(), storage_opts()) :: {:ok, storage_value()} | {:error, term()}
  @callback delete(storage_key()) :: :ok | {:error, term()}
  @callback list(pattern :: term()) :: [storage_key()]
  
  # Tier implementations
  
  defmodule Hot do
    @behaviour Apex.Core.Storage
    
    @ets_tables %{
      data: :apex_hot_data,
      metadata: :apex_hot_metadata,
      ttl: :apex_hot_ttl
    }
    
    def put(key, value, opts) do
      ttl = Keyword.get(opts, :ttl, :infinity)
      compressed = maybe_compress(value, opts)
      
      :ets.insert(@ets_tables.data, {key, compressed})
      
      if ttl != :infinity do
        expiry = System.monotonic_time(:millisecond) + ttl
        :ets.insert(@ets_tables.ttl, {key, expiry})
      end
      
      :ok
    end
    
    def get(key, _opts) do
      case :ets.lookup(@ets_tables.data, key) do
        [{^key, value}] -> {:ok, maybe_decompress(value)}
        [] -> {:error, :not_found}
      end
    end
  end
  
  defmodule Warm do
    @behaviour Apex.Core.Storage
    use GenServer
    
    # Mnesia-based implementation for distributed storage
    def put(key, value, opts) do
      GenServer.call(__MODULE__, {:put, key, value, opts})
    end
  end
  
  defmodule Cold do
    @behaviour Apex.Core.Storage
    
    # External storage adapter system
    def put(key, value, opts) do
      adapter = get_configured_adapter()
      adapter.put(key, value, opts)
    end
  end
end
```

## Event Bus

### Purpose
Provides event-driven communication between components.

### Specification

```elixir
defmodule Apex.Core.EventBus do
  @moduledoc """
  Central event bus for component communication and telemetry.
  """
  
  use GenServer
  
  @type event :: %{
    id: String.t(),
    type: atom(),
    source: atom() | pid(),
    data: term(),
    metadata: map(),
    timestamp: DateTime.t()
  }
  
  @type subscription :: %{
    id: String.t(),
    pattern: pattern(),
    subscriber: pid(),
    filter: filter_fun() | nil,
    transform: transform_fun() | nil
  }
  
  @type pattern :: atom() | {atom(), atom()} | function()
  @type filter_fun :: (event() -> boolean())
  @type transform_fun :: (event() -> term())
  
  # Client API
  
  @spec emit(atom(), term(), keyword()) :: :ok
  def emit(event_type, data, metadata \\ []) do
    event = build_event(event_type, data, metadata)
    GenServer.cast(__MODULE__, {:emit, event})
  end
  
  @spec subscribe(pattern(), keyword()) :: {:ok, subscription_id()} | {:error, term()}
  def subscribe(pattern, opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe, pattern, self(), opts})
  end
  
  @spec unsubscribe(subscription_id()) :: :ok
  def unsubscribe(subscription_id) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id})
  end
  
  # Well-known events
  
  def emit_sandbox_created(sandbox_id, mode, metadata) do
    emit(:sandbox_created, %{id: sandbox_id, mode: mode}, metadata)
  end
  
  def emit_module_loaded(sandbox_id, module, metadata) do
    emit(:module_loaded, %{sandbox_id: sandbox_id, module: module}, metadata)
  end
  
  def emit_state_synced(bridge_id, count, metadata) do
    emit(:state_synced, %{bridge_id: bridge_id, count: count}, metadata)
  end
  
  def emit_security_violation(sandbox_id, violation, metadata) do
    emit(:security_violation, %{sandbox_id: sandbox_id, violation: violation}, 
         Keyword.put(metadata, :severity, :high))
  end
end
```

## Component Integration

### Inter-Component Communication

```elixir
defmodule Apex.Core.Integration do
  @moduledoc """
  Defines how core components interact with each other.
  """
  
  # Module loading triggers state preservation
  def on_module_load(module_info) do
    if module_info.mode == :development do
      Apex.Core.StateManager.create_snapshot(module_info.id)
    end
  end
  
  # Process creation triggers resource allocation
  def on_process_spawn(process_info) do
    Apex.Core.ResourceManager.allocate(
      process_info.sandbox_id,
      process_info.estimated_resources
    )
  end
  
  # State sync triggers security audit
  def on_state_sync(bridge_info) do
    if bridge_info.mode == :hybrid do
      Apex.Core.EventBus.emit(:audit_event, %{
        action: :state_sync,
        bridge: bridge_info.id,
        items: bridge_info.sync_count
      })
    end
  end
end
```

## Next Steps

1. Learn about [Operational Modes](04_operational_modes.md) and their configurations
2. Check [Integration Guide](05_integration_guide.md) for framework support
3. Review [Security Model](06_security_model.md) for security components
4. See [Development Tools](07_development_tools.md) for debugging features
5. Follow [Implementation Guide](08_implementation_guide.md) to build components