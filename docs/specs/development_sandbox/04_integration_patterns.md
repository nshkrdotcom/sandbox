# Development Sandbox Platform - Integration Patterns

## Overview

This document describes various patterns for integrating the Development Sandbox Platform with existing Elixir/Phoenix applications.

## Integration Strategies

### 1. Zero-Configuration Integration

The simplest integration requiring minimal changes to existing applications.

```elixir
# In your mix.exs
defp deps do
  [
    {:dev_sandbox, "~> 1.0", only: [:dev, :test]}
  ]
end

# Automatic attachment in dev environment
# config/dev.exs
config :dev_sandbox,
  auto_attach: true,
  mode: :sidecar,
  features: [:debugging, :profiling]
```

### 2. Explicit Integration

More control over sandbox features and lifecycle.

```elixir
# In your application.ex
defmodule MyApp.Application do
  use Application
  
  def start(_type, _args) do
    children = [
      # Your existing children
      MyApp.Repo,
      MyAppWeb.Endpoint,
      
      # Add Development Sandbox
      {DevSandbox.Supervisor, sandbox_config()}
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  
  defp sandbox_config do
    [
      mode: :embedded,
      features: [:all],
      resource_limits: [
        memory: "1GB",
        cpu: 50
      ]
    ]
  end
end
```

### 3. Conditional Integration

Enable sandbox features based on runtime conditions.

```elixir
defmodule MyApp.DevIntegration do
  def maybe_start_sandbox do
    if sandbox_enabled?() do
      DevSandbox.start_link(
        target: MyApp,
        mode: detect_best_mode(),
        features: configured_features()
      )
    end
  end
  
  defp sandbox_enabled? do
    System.get_env("DEV_SANDBOX_ENABLED", "false") == "true" &&
      Mix.env() in [:dev, :test]
  end
  
  defp detect_best_mode do
    case node() do
      :nonode@nohost -> :embedded
      _ -> :distributed
    end
  end
end
```

## Phoenix-Specific Integration

### 1. Endpoint Integration

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  
  # Development Sandbox UI
  if code_reloading? do
    socket "/dev-sandbox", DevSandbox.Socket,
      websocket: true,
      longpoll: false
    
    plug DevSandbox.Web.Router
  end
  
  # Your existing plugs
  plug Plug.Static, from: :my_app
  plug Phoenix.LiveDashboard.RequestLogger
  plug Plug.RequestId
  plug Plug.Telemetry
  plug Plug.Parsers
  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session
  plug MyAppWeb.Router
end
```

### 2. Router Integration

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  import DevSandbox.Router
  
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, {MyAppWeb.LayoutView, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end
  
  # Development routes
  if Mix.env() == :dev do
    scope "/dev" do
      pipe_through :browser
      
      # Mount development sandbox dashboard
      dev_sandbox_routes()
      
      # Custom development routes
      live "/experiments", DevSandbox.ExperimentsLive
      live "/debug", DevSandbox.DebugLive
      get "/profile", DevSandbox.ProfileController, :index
    end
  end
  
  # Your application routes
  scope "/", MyAppWeb do
    pipe_through :browser
    
    get "/", PageController, :index
    # ...
  end
end
```

### 3. LiveView Integration

```elixir
defmodule MyAppWeb.ProductLive do
  use MyAppWeb, :live_view
  use DevSandbox.LiveView
  
  def mount(params, session, socket) do
    # Development sandbox features
    socket = 
      socket
      |> DevSandbox.LiveView.attach()
      |> DevSandbox.LiveView.enable_debugging()
    
    # Your mount logic
    {:ok,
     socket
     |> assign(:products, list_products())
     |> assign(:filter, %{})}
  end
  
  # Enable live state inspection in development
  if Mix.env() == :dev do
    def handle_event("dev_sandbox:" <> action, params, socket) do
      DevSandbox.LiveView.handle_dev_action(action, params, socket)
    end
  end
  
  # Your existing handlers
  def handle_event("filter", params, socket) do
    # ...
  end
end
```

## GenServer Integration

### 1. Transparent Wrapper

```elixir
defmodule MyApp.Worker do
  use GenServer
  use DevSandbox.GenServer
  
  # Automatically adds development hooks
  # - State inspection
  # - Message tracing
  # - Performance profiling
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def init(opts) do
    # DevSandbox automatically instruments this
    {:ok, %{opts: opts, jobs: []}}
  end
  
  # Your existing callbacks work normally
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end
end
```

### 2. Manual Integration

```elixir
defmodule MyApp.CriticalWorker do
  use GenServer
  
  def init(opts) do
    state = %{opts: opts, jobs: []}
    
    # Manually register with DevSandbox
    if function_exported?(DevSandbox, :register_process, 2) do
      DevSandbox.register_process(self(), 
        type: :worker,
        critical: true,
        inspect: :limited
      )
    end
    
    {:ok, state}
  end
  
  # Selective debugging
  def handle_call(:debug_state, _from, state) do
    if DevSandbox.debugging_enabled?() do
      debug_info = DevSandbox.inspect_state(state)
      {:reply, {:ok, debug_info}, state}
    else
      {:reply, {:error, :not_available}, state}
    end
  end
end
```

## Ecto Integration

### 1. Query Profiling

```elixir
# In your Repo module
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
  
  if Code.ensure_loaded?(DevSandbox) do
    use DevSandbox.Ecto.Profiler
  end
end

# Automatic query profiling in development
# Shows execution time, query plan, and suggestions
```

### 2. Sandbox Transactions

```elixir
defmodule MyApp.DevHelpers do
  def experiment_with_data(changes) do
    DevSandbox.Database.transaction_sandbox(MyApp.Repo, fn ->
      # All changes here are isolated
      # Automatically rolled back
      
      Enum.each(changes, fn change ->
        MyApp.Repo.insert!(change)
      end)
      
      # Test queries and see results
      results = MyApp.Repo.all(MyApp.Product)
      
      # Analyze performance
      DevSandbox.Database.explain(results)
    end)
  end
end
```

## Telemetry Integration

### 1. Automatic Instrumentation

```elixir
# In your application.ex
def start(_type, _args) do
  # Setup DevSandbox telemetry
  DevSandbox.Telemetry.attach_all()
  
  # Your existing telemetry
  MyApp.Telemetry.setup()
  
  # ...
end
```

### 2. Custom Metrics

```elixir
defmodule MyApp.Telemetry do
  def setup do
    # Your metrics
    metrics = [
      counter("http.request.count"),
      distribution("http.request.duration", unit: :millisecond)
    ]
    
    # Add DevSandbox metrics
    dev_metrics = if Mix.env() == :dev do
      DevSandbox.Telemetry.development_metrics()
    else
      []
    end
    
    # Start reporters
    Telemetry.Metrics.ConsoleReporter.start_link(
      metrics: metrics ++ dev_metrics
    )
  end
end
```

## Testing Integration

### 1. ExUnit Integration

```elixir
# In test_helper.exs
ExUnit.start()

# Enable DevSandbox test mode
DevSandbox.Test.setup()

# In your tests
defmodule MyApp.FeatureTest do
  use MyApp.DataCase
  use DevSandbox.Test
  
  test "complex scenario" do
    # Record the test execution
    DevSandbox.Test.record() do
      # Your test code
      user = insert(:user)
      product = insert(:product)
      
      assert {:ok, order} = OrderService.create(user, product)
    end
    
    # Analyze what happened
    recording = DevSandbox.Test.last_recording()
    assert recording.query_count < 10
    assert recording.memory_peak < 50_000_000
  end
  
  @tag :performance
  test "performance regression" do
    DevSandbox.Test.benchmark "order creation" do
      OrderService.create_bulk(100)
    end
    
    # Automatically compared against baseline
    # Fails if performance degrades
  end
end
```

### 2. Property Testing Integration

```elixir
defmodule MyApp.PropertyTest do
  use ExUnit.Case
  use ExUnitProperties
  use DevSandbox.PropertyTest
  
  property "orders are always valid" do
    check all order_params <- order_generator() do
      # DevSandbox tracks each generation
      DevSandbox.PropertyTest.track() do
        case OrderService.create(order_params) do
          {:ok, order} -> assert valid_order?(order)
          {:error, _} -> :ok
        end
      end
    end
    
    # After test, analyze patterns
    analysis = DevSandbox.PropertyTest.analyze()
    IO.inspect(analysis.failure_patterns)
  end
end
```

## Cluster Integration

### 1. Multi-Node Setup

```elixir
# config/dev.exs
config :dev_sandbox,
  cluster: [
    strategy: :gossip,
    nodes: [
      {:main, "main@localhost"},
      {:sandbox, "sandbox@localhost"},
      {:debug, "debug@localhost"}
    ]
  ]

# In your application
defmodule MyApp.ClusterSetup do
  def setup_development_cluster do
    if DevSandbox.cluster_enabled?() do
      DevSandbox.Cluster.start_nodes()
      DevSandbox.Cluster.connect_all()
      
      # Distribute components
      DevSandbox.Cluster.deploy_component(:profiler, :debug)
      DevSandbox.Cluster.deploy_component(:experiments, :sandbox)
    end
  end
end
```

### 2. Distributed Debugging

```elixir
defmodule MyApp.DistributedWorker do
  use GenServer
  
  def handle_call({:process, data}, from, state) do
    # Enable distributed tracing
    DevSandbox.Trace.with_context from: from do
      # Process across multiple nodes
      step1 = RemoteNode.process_part1(data)
      step2 = OtherNode.process_part2(step1)
      result = final_processing(step2)
      
      {:reply, result, state}
    end
  end
end

# View the distributed trace
DevSandbox.Trace.visualize(:latest)
```

## Custom Integration Patterns

### 1. Plugin Architecture

```elixir
defmodule MyApp.DevPlugin do
  use DevSandbox.Plugin
  
  def init(config) do
    {:ok, %{config: config}}
  end
  
  def handle_event({:code_modified, module}, state) do
    # Custom handling for code changes
    if module in MyApp.critical_modules() do
      Logger.warn("Critical module #{module} modified")
      DevSandbox.Notification.send("Review required for #{module}")
    end
    
    {:ok, state}
  end
  
  def custom_commands do
    [
      {"app:reset", &reset_application/1},
      {"app:seed", &seed_test_data/1}
    ]
  end
end

# Register plugin
DevSandbox.register_plugin(MyApp.DevPlugin)
```

### 2. Middleware Pattern

```elixir
defmodule MyApp.DevMiddleware do
  def wrap_operation(fun, metadata \\ %{}) do
    if DevSandbox.active?() do
      DevSandbox.Operation.track metadata do
        # Pre-operation hooks
        DevSandbox.Hooks.before_operation(metadata)
        
        # Execute operation
        result = fun.()
        
        # Post-operation hooks
        DevSandbox.Hooks.after_operation(metadata, result)
        
        result
      end
    else
      fun.()
    end
  end
end

# Usage
def complex_operation(params) do
  MyApp.DevMiddleware.wrap_operation fn ->
    # Your operation code
  end, %{operation: "complex_operation", params: params}
end
```

## Configuration Patterns

### 1. Environment-Specific Configuration

```elixir
# config/dev.exs
config :dev_sandbox,
  enabled: true,
  features: [
    debugging: [
      level: :verbose,
      include_private: true
    ],
    profiling: [
      sample_rate: 1000,
      include_ets: true
    ],
    experiments: [
      isolation: :full,
      resource_limits: :strict
    ]
  ]

# config/prod.exs
config :dev_sandbox,
  enabled: false  # Completely disabled in production
```

### 2. Dynamic Configuration

```elixir
defmodule MyApp.DevConfig do
  def configure_sandbox do
    DevSandbox.configure(
      features: determine_features(),
      limits: calculate_limits(),
      security: security_policy()
    )
  end
  
  defp determine_features do
    base_features = [:debugging, :profiling]
    
    additional = 
      if powerful_machine?() do
        [:experiments, :time_travel]
      else
        []
      end
    
    base_features ++ additional
  end
  
  defp calculate_limits do
    %{
      memory: "#{available_memory() * 0.2}MB",
      cpu: 25,
      processes: 10_000
    }
  end
end
```

## Migration Strategies

### 1. Gradual Adoption

```elixir
# Phase 1: Start with debugging only
config :dev_sandbox, features: [:debugging]

# Phase 2: Add profiling
config :dev_sandbox, features: [:debugging, :profiling]

# Phase 3: Enable experiments
config :dev_sandbox, features: [:debugging, :profiling, :experiments]

# Phase 4: Full platform
config :dev_sandbox, features: :all
```

### 2. Feature Flags

```elixir
defmodule MyApp.Features do
  def sandbox_enabled?, do: flag?(:dev_sandbox)
  def sandbox_debugging?, do: flag?(:dev_sandbox_debug)
  def sandbox_profiling?, do: flag?(:dev_sandbox_profile)
  
  def with_sandbox(fun) do
    if sandbox_enabled?() do
      DevSandbox.wrap(fun)
    else
      fun.()
    end
  end
end
```

## Best Practices

### 1. Isolation Boundaries

```elixir
# Good: Clear boundaries
defmodule MyApp.Business do
  # Business logic without dev dependencies
end

defmodule MyApp.Business.Dev do
  # Development-specific extensions
  require MyApp.Business
  
  def inspect_state do
    if Code.ensure_loaded?(DevSandbox) do
      DevSandbox.inspect(MyApp.Business)
    end
  end
end
```

### 2. Performance Considerations

```elixir
# Use compile-time checks
defmodule MyApp.Instrumented do
  if Mix.env() == :dev do
    use DevSandbox.Instrumentation
  end
  
  def process(data) do
    # Instrumentation only added in dev
    do_process(data)
  end
end
```

## Next Steps

1. Learn about [Advanced Features](05_advanced_features.md) for powerful capabilities
2. Follow the [Implementation Guide](06_implementation_guide.md) to get started
3. Review [API Reference](07_api_reference.md) for detailed API documentation
4. Check [Troubleshooting Guide](08_troubleshooting.md) for common issues