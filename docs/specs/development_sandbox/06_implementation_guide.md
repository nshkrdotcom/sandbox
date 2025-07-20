# Development Sandbox Platform - Implementation Guide

## Overview

This guide provides step-by-step instructions for implementing the Development Sandbox Platform, from initial setup to advanced deployments.

## Phase 1: Foundation (Weeks 1-4)

### Week 1: Core Infrastructure

#### 1.1 Project Setup

```elixir
# mix.exs
defmodule DevSandbox.MixProject do
  use Mix.Project

  def project do
    [
      app: :dev_sandbox,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      dialyzer: [
        plt_add_apps: [:erts, :kernel, :stdlib],
        flags: [:error_handling, :race_conditions, :unmatched_returns]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools, :observer],
      mod: {DevSandbox.Application, []}
    ]
  end

  defp deps do
    [
      # Core dependencies
      {:phoenix, "~> 1.7", optional: true},
      {:phoenix_live_view, "~> 0.19", optional: true},
      
      # Development tools
      {:ex_doc, "~> 0.30", only: :dev, runtime: false},
      {:dialyxir, "~> 1.3", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      
      # Testing
      {:stream_data, "~> 0.6", only: :test},
      {:mox, "~> 1.0", only: :test},
      
      # Monitoring
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      
      # Storage
      {:cachex, "~> 3.6"},
      
      # Security
      {:sobelow, "~> 0.12", only: [:dev, :test], runtime: false},
      
      # Utilities
      {:jason, "~> 1.4"},
      {:nimble_parsec, "~> 1.3"}
    ]
  end
end
```

#### 1.2 Application Structure

```bash
dev_sandbox/
├── lib/
│   ├── dev_sandbox/
│   │   ├── application.ex
│   │   ├── supervisor.ex
│   │   ├── harness/
│   │   │   ├── harness.ex
│   │   │   ├── attachment.ex
│   │   │   └── discovery.ex
│   │   ├── state_bridge/
│   │   │   ├── bridge.ex
│   │   │   ├── synchronizer.ex
│   │   │   └── transformer.ex
│   │   ├── core/
│   │   │   ├── registry.ex
│   │   │   ├── event_bus.ex
│   │   │   └── config.ex
│   │   └── storage/
│   │       ├── ets_storage.ex
│   │       └── persistent_storage.ex
│   └── dev_sandbox.ex
├── test/
├── config/
└── mix.exs
```

#### 1.3 Core Supervisor

```elixir
defmodule DevSandbox.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    children = [
      # Core registry for tracking components
      {Registry, keys: :unique, name: DevSandbox.Registry},
      
      # Event bus for inter-component communication
      {DevSandbox.EventBus, []},
      
      # Configuration manager
      {DevSandbox.Config, []},
      
      # Storage layer
      {DevSandbox.Storage.Supervisor, []},
      
      # Dynamic supervisor for sandboxes
      {DynamicSupervisor, 
       strategy: :one_for_one,
       name: DevSandbox.SandboxSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### Week 2: Harness Implementation

#### 2.1 Basic Harness

```elixir
defmodule DevSandbox.Harness do
  use GenServer
  require Logger

  defstruct [
    :target_app,
    :mode,
    :connection,
    :monitors,
    :config,
    status: :initializing
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def init(opts) do
    state = %__MODULE__{
      target_app: opts[:target_app],
      mode: opts[:mode] || :sidecar,
      config: opts[:config] || %{}
    }
    
    {:ok, state, {:continue, :attach}}
  end

  def handle_continue(:attach, state) do
    case attach_to_application(state) do
      {:ok, connection} ->
        monitors = start_monitors(connection, state.config)
        {:noreply, %{state | connection: connection, monitors: monitors, status: :connected}}
        
      {:error, reason} ->
        Logger.error("Failed to attach to application: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  defp attach_to_application(%{mode: :sidecar} = state) do
    DevSandbox.Harness.Attachment.attach_sidecar(state.target_app)
  end

  defp attach_to_application(%{mode: :embedded} = state) do
    DevSandbox.Harness.Attachment.attach_embedded(state.target_app)
  end

  defp start_monitors(connection, config) do
    monitors = [
      start_process_monitor(connection, config),
      start_ets_monitor(connection, config),
      start_memory_monitor(connection, config)
    ]
    
    Enum.filter(monitors, &match?({:ok, _}, &1))
    |> Enum.map(fn {:ok, pid} -> pid end)
  end
end
```

#### 2.2 Discovery System

```elixir
defmodule DevSandbox.Harness.Discovery do
  @moduledoc """
  Discovers and analyzes application structure.
  """

  def discover_application(app_name) when is_atom(app_name) do
    with {:ok, app_info} <- get_application_info(app_name),
         {:ok, sup_tree} <- analyze_supervision_tree(app_info),
         {:ok, processes} <- discover_processes(app_name),
         {:ok, ets_tables} <- discover_ets_tables() do
      
      %{
        app_info: app_info,
        supervision_tree: sup_tree,
        processes: processes,
        ets_tables: ets_tables,
        modules: get_loaded_modules(app_name),
        configuration: get_configuration(app_name)
      }
    end
  end

  defp analyze_supervision_tree(app_info) do
    case app_info[:mod] do
      {mod, _args} ->
        analyze_supervisor(mod)
      _ ->
        {:ok, %{}}
    end
  end

  defp analyze_supervisor(supervisor) do
    children = Supervisor.which_children(supervisor)
    
    tree = Enum.map(children, fn {id, pid, type, modules} ->
      child_info = %{
        id: id,
        pid: pid,
        type: type,
        modules: modules
      }
      
      # Recursively analyze child supervisors
      if type == :supervisor and is_pid(pid) do
        case analyze_supervisor(pid) do
          {:ok, sub_tree} ->
            Map.put(child_info, :children, sub_tree)
          _ ->
            child_info
        end
      else
        child_info
      end
    end)
    
    {:ok, tree}
  end
end
```

### Week 3: State Bridge Implementation

#### 3.1 State Bridge Core

```elixir
defmodule DevSandbox.StateBridge do
  use GenServer
  require Logger

  defstruct [
    :source,
    :target,
    :mode,
    :strategy,
    :filters,
    :transformers,
    :buffer,
    :sync_interval,
    subscriptions: %{},
    last_sync: nil
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def init(opts) do
    state = %__MODULE__{
      source: opts[:source],
      target: opts[:target],
      mode: opts[:mode] || :push,
      strategy: opts[:strategy] || :lazy,
      filters: opts[:filters] || [],
      transformers: opts[:transformers] || [],
      buffer: :queue.new(),
      sync_interval: opts[:sync_interval] || 1000
    }
    
    schedule_sync(state)
    {:ok, state}
  end

  def sync_now(bridge) do
    GenServer.call(bridge, :sync_now)
  end

  def add_filter(bridge, filter) do
    GenServer.call(bridge, {:add_filter, filter})
  end

  def handle_call(:sync_now, _from, state) do
    {result, new_state} = perform_sync(state)
    {:reply, result, new_state}
  end

  def handle_call({:add_filter, filter}, _from, state) do
    new_filters = [compile_filter(filter) | state.filters]
    {:reply, :ok, %{state | filters: new_filters}}
  end

  def handle_info(:scheduled_sync, state) do
    {_result, new_state} = perform_sync(state)
    schedule_sync(new_state)
    {:noreply, new_state}
  end

  defp perform_sync(state) do
    start_time = System.monotonic_time(:millisecond)
    
    try do
      # Collect state from source
      source_state = collect_state(state.source, state.filters)
      
      # Transform state
      transformed = apply_transformers(source_state, state.transformers)
      
      # Apply to target
      apply_state(state.target, transformed, state.mode)
      
      duration = System.monotonic_time(:millisecond) - start_time
      
      result = {:ok, %{
        items_synced: map_size(transformed),
        duration: duration,
        timestamp: DateTime.utc_now()
      }}
      
      {result, %{state | last_sync: DateTime.utc_now()}}
    rescue
      error ->
        Logger.error("Sync failed: #{inspect(error)}")
        {{:error, error}, state}
    end
  end

  defp schedule_sync(%{strategy: :periodic} = state) do
    Process.send_after(self(), :scheduled_sync, state.sync_interval)
  end
  defp schedule_sync(_state), do: :ok
end
```

#### 3.2 State Transformers

```elixir
defmodule DevSandbox.StateBridge.Transformer do
  @moduledoc """
  Transforms state during synchronization.
  """

  def identity, do: &Function.identity/1

  def redact_sensitive(keys) do
    fn state ->
      Enum.reduce(keys, state, fn key, acc ->
        update_in_path(acc, key, fn _ -> "[REDACTED]" end)
      end)
    end
  end

  def rename_keys(mapping) do
    fn state ->
      Enum.reduce(mapping, state, fn {old_key, new_key}, acc ->
        case Map.pop(acc, old_key) do
          {value, new_acc} ->
            Map.put(new_acc, new_key, value)
          _ ->
            acc
        end
      end)
    end
  end

  def filter_keys(allowed_keys) do
    fn state ->
      Map.take(state, allowed_keys)
    end
  end

  def compose(transformers) do
    fn state ->
      Enum.reduce(transformers, state, fn transformer, acc ->
        transformer.(acc)
      end)
    end
  end

  defp update_in_path(map, path, fun) when is_list(path) do
    update_in(map, path, fun)
  rescue
    _ -> map
  end
  defp update_in_path(map, key, fun) do
    update_in_path(map, [key], fun)
  end
end
```

### Week 4: Basic Integration

#### 4.1 Phoenix Integration Module

```elixir
defmodule DevSandbox.Phoenix do
  @moduledoc """
  Phoenix-specific integration for DevSandbox.
  """

  defmacro __using__(opts) do
    quote do
      @dev_sandbox_opts unquote(opts)
      
      def dev_sandbox_enabled? do
        Application.get_env(:dev_sandbox, :enabled, Mix.env() == :dev)
      end
      
      def with_dev_sandbox(fun) do
        if dev_sandbox_enabled?() do
          DevSandbox.wrap_operation(fun, @dev_sandbox_opts)
        else
          fun.()
        end
      end
    end
  end

  def integrate(endpoint_module) do
    if enabled?() do
      # Add DevSandbox socket
      endpoint_module.socket("/dev-sandbox", DevSandbox.Phoenix.Socket,
        websocket: true,
        longpoll: false
      )
      
      # Start harness
      {:ok, _harness} = DevSandbox.Harness.start_link(
        target_app: endpoint_module.config(:otp_app),
        mode: :embedded
      )
    end
  end

  defp enabled? do
    Application.get_env(:dev_sandbox, :enabled, false)
  end
end
```

#### 4.2 Testing Framework

```elixir
defmodule DevSandbox.Test do
  @moduledoc """
  Testing utilities for DevSandbox.
  """

  defmodule Case do
    use ExUnit.CaseTemplate

    using do
      quote do
        import DevSandbox.Test.Helpers
        
        setup_all do
          {:ok, _} = start_supervised(DevSandbox.Supervisor)
          :ok
        end
      end
    end
  end

  def start_harness_test do
    test "harness attaches to application" do
      {:ok, harness} = DevSandbox.Harness.start_link(
        target_app: :test_app,
        mode: :sidecar
      )
      
      assert DevSandbox.Harness.connected?(harness)
    end
  end

  def state_bridge_test do
    test "state bridge synchronizes data" do
      source = spawn_source_process()
      target = spawn_target_process()
      
      {:ok, bridge} = DevSandbox.StateBridge.start_link(
        source: source,
        target: target,
        mode: :push
      )
      
      # Modify source state
      send(source, {:update, %{key: "value"}})
      
      # Trigger sync
      DevSandbox.StateBridge.sync_now(bridge)
      
      # Verify target received update
      assert get_state(target) == %{key: "value"}
    end
  end
end
```

## Phase 2: Core Features (Weeks 5-8)

### Week 5: Code Experimentation Engine

```elixir
defmodule DevSandbox.Experimentation do
  use GenServer

  def create(name, base_modules, opts \\ []) do
    GenServer.call(__MODULE__, {:create, name, base_modules, opts})
  end

  def add_variant(experiment_id, name, code) do
    GenServer.call(__MODULE__, {:add_variant, experiment_id, name, code})
  end

  def run(experiment_id, test_data) do
    GenServer.call(__MODULE__, {:run, experiment_id, test_data}, :infinity)
  end

  def handle_call({:create, name, base_modules, opts}, _from, state) do
    experiment = %{
      id: generate_id(),
      name: name,
      base_modules: base_modules,
      variants: %{},
      created_at: DateTime.utc_now(),
      options: opts
    }
    
    new_state = Map.put(state.experiments, experiment.id, experiment)
    {:reply, {:ok, experiment}, %{state | experiments: new_state}}
  end

  def handle_call({:run, experiment_id, test_data}, _from, state) do
    case Map.get(state.experiments, experiment_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
        
      experiment ->
        results = run_experiment(experiment, test_data)
        {:reply, {:ok, results}, state}
    end
  end

  defp run_experiment(experiment, test_data) do
    # Create isolated environments for each variant
    results = Enum.map(experiment.variants, fn {name, variant} ->
      sandbox = create_sandbox(experiment.options)
      
      try do
        # Load variant code
        load_variant_code(sandbox, variant)
        
        # Run test
        {time, result} = :timer.tc(fn ->
          execute_in_sandbox(sandbox, test_data)
        end)
        
        {name, %{result: result, time: time, metrics: collect_metrics(sandbox)}}
      after
        cleanup_sandbox(sandbox)
      end
    end)
    
    %{
      results: Map.new(results),
      comparison: compare_results(results),
      winner: determine_winner(results)
    }
  end
end
```

### Week 6: Debug Orchestrator

```elixir
defmodule DevSandbox.Debug do
  use GenServer

  defstruct [
    :session_id,
    :target_nodes,
    :breakpoints,
    :watches,
    :recording,
    :mode
  ]

  def start_session(nodes, opts \\ []) do
    GenServer.start_link(__MODULE__, {nodes, opts})
  end

  def set_breakpoint(session, module, line, condition \\ nil) do
    GenServer.call(session, {:set_breakpoint, module, line, condition})
  end

  def step(session, type \\ :into) do
    GenServer.call(session, {:step, type})
  end

  def handle_call({:set_breakpoint, module, line, condition}, _from, state) do
    breakpoint = %{
      id: generate_id(),
      module: module,
      line: line,
      condition: condition,
      hits: 0
    }
    
    # Install breakpoint on all nodes
    Enum.each(state.target_nodes, fn node ->
      install_breakpoint(node, breakpoint)
    end)
    
    new_breakpoints = [breakpoint | state.breakpoints]
    {:reply, {:ok, breakpoint.id}, %{state | breakpoints: new_breakpoints}}
  end

  defp install_breakpoint(node, breakpoint) do
    :rpc.call(node, :int, :break, [breakpoint.module, breakpoint.line])
    
    if breakpoint.condition do
      :rpc.call(node, :int, :test_at_break, [
        breakpoint.module,
        breakpoint.line,
        compile_condition(breakpoint.condition)
      ])
    end
  end
end
```

### Week 7: Performance Studio

```elixir
defmodule DevSandbox.Performance do
  use GenServer

  def start_profiling(target, type, opts \\ []) do
    GenServer.call(__MODULE__, {:start_profiling, target, type, opts})
  end

  def stop_profiling(session_id) do
    GenServer.call(__MODULE__, {:stop_profiling, session_id})
  end

  def analyze(session_id) do
    GenServer.call(__MODULE__, {:analyze, session_id})
  end

  def handle_call({:start_profiling, target, type, opts}, _from, state) do
    session = start_profiler(target, type, opts)
    new_sessions = Map.put(state.sessions, session.id, session)
    {:reply, {:ok, session.id}, %{state | sessions: new_sessions}}
  end

  defp start_profiler(target, :cpu, opts) do
    # Use :eprof or :fprof based on requirements
    ref = make_ref()
    
    profiler = case opts[:mode] do
      :detailed -> :fprof
      _ -> :eprof
    end
    
    profiler.start()
    profiler.trace([target])
    
    %{
      id: ref,
      type: :cpu,
      profiler: profiler,
      target: target,
      start_time: System.monotonic_time(),
      options: opts
    }
  end

  defp start_profiler(target, :memory, opts) do
    # Custom memory profiling
    ref = make_ref()
    
    # Start collecting memory samples
    {:ok, collector} = DevSandbox.Performance.MemoryCollector.start_link(
      target: target,
      interval: opts[:interval] || 100
    )
    
    %{
      id: ref,
      type: :memory,
      collector: collector,
      target: target,
      start_time: System.monotonic_time(),
      options: opts
    }
  end
end
```

### Week 8: Security Controller

```elixir
defmodule DevSandbox.Security do
  use GenServer

  def check_code(code) do
    GenServer.call(__MODULE__, {:check_code, code})
  end

  def apply_policy(sandbox, policy) do
    GenServer.call(__MODULE__, {:apply_policy, sandbox, policy})
  end

  def audit_action(action, context) do
    GenServer.cast(__MODULE__, {:audit, action, context})
  end

  def handle_call({:check_code, code}, _from, state) do
    analysis = analyze_code_security(code, state.policies)
    {:reply, analysis, state}
  end

  defp analyze_code_security(code, policies) do
    try do
      ast = Code.string_to_quoted!(code)
      
      issues = []
      |> check_dangerous_functions(ast, policies)
      |> check_system_access(ast, policies)
      |> check_network_access(ast, policies)
      |> check_file_access(ast, policies)
      
      %{
        safe: Enum.empty?(issues),
        issues: issues,
        risk_level: calculate_risk_level(issues)
      }
    rescue
      _ ->
        %{safe: false, issues: [:parse_error], risk_level: :high}
    end
  end

  defp check_dangerous_functions(issues, ast, policies) do
    dangerous = [
      {System, :cmd},
      {File, :rm_rf},
      {:erlang, :halt},
      {Port, :open}
    ]
    
    walker = fn
      {{:., _, [{:__aliases__, _, module_parts}, func]}, _, _} = node, acc ->
        module = Module.concat(module_parts)
        if {module, func} in dangerous do
          [{:dangerous_function, {module, func}, node} | acc]
        else
          acc
        end
        
      _, acc -> acc
    end
    
    found = Macro.prewalk(ast, issues, walker)
    found
  end
end
```

## Phase 3: Advanced Integration (Weeks 9-12)

### Week 9-10: Phoenix/LiveView Integration

```elixir
defmodule DevSandbox.Phoenix.LiveView do
  @moduledoc """
  LiveView-specific development tools.
  """

  defmacro __using__(_opts) do
    quote do
      import DevSandbox.Phoenix.LiveView
      
      def handle_event("devsandbox:" <> action, params, socket) do
        DevSandbox.Phoenix.LiveView.handle_action(action, params, socket)
      end
      
      def handle_info({:devsandbox, message}, socket) do
        DevSandbox.Phoenix.LiveView.handle_message(message, socket)
      end
    end
  end

  def attach(socket) do
    if enabled?() do
      socket
      |> assign(:__devsandbox__, %{
        attached: true,
        session_id: generate_session_id(),
        debug_mode: false
      })
      |> attach_hooks()
    else
      socket
    end
  end

  def handle_action("inspect", %{"path" => path}, socket) do
    value = get_in(socket.assigns, String.split(path, "."))
    {:reply, %{value: inspect(value)}, socket}
  end

  def handle_action("toggle_debug", _params, socket) do
    debug_mode = !socket.assigns.__devsandbox__.debug_mode
    
    socket = 
      socket
      |> assign_devsandbox(:debug_mode, debug_mode)
      |> push_event("devsandbox:debug_mode", %{enabled: debug_mode})
    
    {:noreply, socket}
  end

  defp attach_hooks(socket) do
    socket
    |> attach_hook(:devsandbox_mount, :handle_params, &debug_params/3)
    |> attach_hook(:devsandbox_event, :handle_event, &debug_event/3)
  end
end
```

### Week 11-12: Deployment and Documentation

#### Deployment Configuration

```elixir
# config/releases.exs
import Config

config :dev_sandbox,
  deployment_mode: System.get_env("DEV_SANDBOX_MODE", "disabled"),
  cluster_nodes: System.get_env("DEV_SANDBOX_NODES", "")
    |> String.split(",", trim: true),
  security_level: System.get_env("DEV_SANDBOX_SECURITY", "high"),
  features: System.get_env("DEV_SANDBOX_FEATURES", "basic")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1)
```

#### Docker Support

```dockerfile
# Dockerfile.devsandbox
FROM elixir:1.14-alpine AS build

RUN apk add --no-cache build-base git

WORKDIR /app

# Install hex and rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Copy deps
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && \
    mix deps.compile

# Copy source
COPY lib lib
COPY priv priv

# Compile
RUN mix compile

# Build release
RUN mix release dev_sandbox

# Runtime stage
FROM alpine:3.18

RUN apk add --no-cache openssl ncurses-libs libstdc++

WORKDIR /app

COPY --from=build /app/_build/prod/rel/dev_sandbox ./

ENV HOME=/app

CMD ["bin/dev_sandbox", "start"]
```

## Testing Strategy

### Unit Tests

```elixir
defmodule DevSandbox.HarnessTest do
  use DevSandbox.Test.Case

  describe "attachment" do
    test "attaches to running application" do
      # Start test application
      {:ok, _} = start_supervised(TestApp)
      
      # Attach harness
      {:ok, harness} = DevSandbox.Harness.attach(TestApp, mode: :sidecar)
      
      # Verify connection
      assert DevSandbox.Harness.connected?(harness)
      assert {:ok, _} = DevSandbox.Harness.discover(harness)
    end
  end
end
```

### Integration Tests

```elixir
defmodule DevSandbox.IntegrationTest do
  use DevSandbox.Test.Case

  @tag :integration
  test "full development session" do
    # Start Phoenix app
    {:ok, _} = start_supervised(TestPhoenixApp)
    
    # Attach DevSandbox
    {:ok, harness} = DevSandbox.attach(TestPhoenixApp)
    
    # Create experiment
    {:ok, exp} = DevSandbox.Experimentation.create("optimize_query")
    
    # Add variant
    :ok = DevSandbox.Experimentation.add_variant(exp, :optimized, """
    def query(params) do
      # Optimized implementation
    end
    """)
    
    # Run experiment
    {:ok, results} = DevSandbox.Experimentation.run(exp, test_data())
    
    # Verify results
    assert results.winner == :optimized
    assert results.comparison.improvement > 20
  end
end
```

## Monitoring and Metrics

```elixir
defmodule DevSandbox.Telemetry do
  def setup do
    metrics = [
      # Harness metrics
      counter("devsandbox.harness.attachment.count"),
      distribution("devsandbox.harness.discovery.duration"),
      
      # State bridge metrics
      counter("devsandbox.state_bridge.sync.count"),
      distribution("devsandbox.state_bridge.sync.duration"),
      summary("devsandbox.state_bridge.sync.items"),
      
      # Experimentation metrics
      counter("devsandbox.experiment.created.count"),
      counter("devsandbox.experiment.run.count"),
      distribution("devsandbox.experiment.run.duration"),
      
      # Performance metrics
      counter("devsandbox.profiling.session.count"),
      distribution("devsandbox.profiling.overhead.percentage")
    ]
    
    # Attach handlers
    :telemetry.attach_many(
      "devsandbox-metrics",
      [
        [:devsandbox, :harness, :attached],
        [:devsandbox, :state_bridge, :synced],
        [:devsandbox, :experiment, :completed]
      ],
      &handle_event/4,
      nil
    )
  end
end
```

## Next Steps

1. Review [API Reference](07_api_reference.md) for detailed API documentation
2. Check [Troubleshooting Guide](08_troubleshooting.md) for common issues
3. See [Performance Tuning](09_performance_tuning.md) for optimization
4. Read [Security Guidelines](10_security_guidelines.md) for best practices