# Apex Platform - Integration Guide

## Overview

This guide provides comprehensive instructions for integrating the Apex Platform with various Elixir frameworks and libraries. Each integration is designed to work seamlessly with all three operational modes.

## Quick Start

### Installation

```elixir
# mix.exs
def deps do
  [
    {:apex, "~> 2.0"},
    
    # Optional integrations
    {:apex_phoenix, "~> 2.0", only: [:dev, :test]},
    {:apex_ecto, "~> 2.0", only: [:dev, :test]},
    {:apex_otp, "~> 2.0", only: [:dev, :test]}
  ]
end
```

### Basic Configuration

```elixir
# config/config.exs
config :apex,
  default_mode: :hybrid,
  auto_start: false,
  integrations: [:phoenix, :ecto, :otp]

# config/dev.exs
config :apex,
  default_mode: :development,
  auto_start: true,
  features: [:debugging, :profiling, :hot_reload]

# config/prod.exs
config :apex,
  default_mode: :isolation,
  auto_start: false,
  security_profile: :strict
```

## Phoenix Integration

### Endpoint Integration

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  use Apex.Phoenix.Endpoint
  
  # Development-only routes
  if Application.compile_env(:my_app, :dev_routes, false) do
    apex_routes "/dev",
      mode: :development,
      features: [:dashboard, :profiler, :debugger],
      authorization: {MyApp.Auth, :check_developer}
  end
  
  # Sandbox API routes
  apex_api "/api/sandbox",
    mode: :isolation,
    rate_limit: 100,
    authentication: :required
  
  # Your regular plugs...
  plug Plug.Static
  plug Phoenix.Router
end
```

### Router Integration

```elixir
defmodule MyAppWeb.Router do
  use MyAppWeb, :router
  use Apex.Phoenix.Router
  
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end
  
  pipeline :apex_dev do
    plug Apex.Phoenix.Plugs.DevelopmentAuth
    plug Apex.Phoenix.Plugs.ModeSelector
    plug Apex.Phoenix.Plugs.FeatureGate
  end
  
  # Development tools (only in dev/test)
  if Mix.env() in [:dev, :test] do
    scope "/dev", Apex.Phoenix do
      pipe_through [:browser, :apex_dev]
      
      # Dashboard
      live "/", DashboardLive
      
      # Debugging tools
      live "/debug", DebuggerLive
      live "/debug/:pid", ProcessInspectorLive
      
      # Profiling
      live "/profiler", ProfilerLive
      get "/profiler/export/:id", ProfilerController, :export
      
      # Experimentation
      live "/experiments", ExperimentLive
      post "/experiments/:id/run", ExperimentController, :run
      
      # Time-travel debugging
      live "/timetravel", TimeTravelLive
      
      # Sandbox management
      resources "/sandboxes", SandboxController
    end
  end
  
  # Production sandbox API
  scope "/api/sandbox", Apex.Phoenix.API do
    pipe_through :api
    
    post "/execute", SandboxController, :execute
    get "/status/:id", SandboxController, :status
  end
end
```

### LiveView Integration

```elixir
defmodule MyAppWeb.MyLive do
  use MyAppWeb, :live_view
  use Apex.Phoenix.LiveView
  
  @impl true
  def mount(_params, _session, socket) do
    # Automatically adds development hooks in dev mode
    socket = 
      socket
      |> assign(:data, load_data())
      |> apex_attach(mode: current_mode())
    
    {:ok, socket}
  end
  
  # Development mode: State inspection and manipulation
  @impl true
  def handle_event("apex:inspect", %{"path" => path}, socket) do
    value = get_in(socket.assigns, String.split(path, "."))
    {:reply, %{value: inspect(value, pretty: true)}, socket}
  end
  
  @impl true
  def handle_event("apex:update", %{"path" => path, "value" => value}, socket) do
    # Only in development mode with permissions
    if apex_can?(socket, :state_manipulation) do
      socket = put_in(socket.assigns, String.split(path, "."), value)
      {:noreply, socket}
    else
      {:reply, %{error: "Permission denied"}, socket}
    end
  end
  
  # Time-travel debugging integration
  @impl true
  def handle_info({:apex, :replay, snapshot}, socket) do
    socket = apex_restore_snapshot(socket, snapshot)
    {:noreply, socket}
  end
end
```

### LiveView Hooks

```javascript
// assets/js/apex_hooks.js
export const ApexHooks = {
  ApexInspector: {
    mounted() {
      // Enable CMD+Click to inspect elements
      this.el.addEventListener("click", (e) => {
        if (e.metaKey || e.ctrlKey) {
          e.preventDefault()
          const path = this.el.dataset.apexPath
          this.pushEvent("apex:inspect", {path: path})
        }
      })
    }
  },
  
  ApexProfiler: {
    mounted() {
      // Real-time performance metrics
      this.metrics = []
      this.handleEvent("apex:metrics", ({metrics}) => {
        this.metrics.push(metrics)
        this.updateChart()
      })
    }
  }
}

// app.js
import {ApexHooks} from "./apex_hooks"

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: {...Hooks, ...ApexHooks},
  params: {_csrf_token: csrfToken}
})
```

## Ecto Integration

### Repository Integration

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
  
  use Apex.Ecto.Repo
  
  # Adds query profiling and analysis in development
  if Mix.env() == :dev do
    def default_options(_operation) do
      [telemetry_options: [apex_profile: true]]
    end
  end
end
```

### Query Profiling

```elixir
defmodule MyApp.Products do
  import Ecto.Query
  alias MyApp.Repo
  
  def list_products(opts \\ []) do
    base_query = from p in Product, preload: [:category, :reviews]
    
    # Automatic profiling in development mode
    query = if apex_profiling?() do
      base_query
      |> Apex.Ecto.profile()
      |> Apex.Ecto.explain(analyze: true)
    else
      base_query
    end
    
    Repo.all(query, opts)
  end
end
```

### Migration Sandboxing

```elixir
defmodule MyApp.Repo.Migrations.AddNewFeature do
  use Ecto.Migration
  use Apex.Ecto.Migration
  
  # Test migration in sandbox before running
  @apex_sandbox mode: :hybrid,
                test_data: "priv/repo/test_data.sql",
                rollback_test: true
  
  def up do
    create table(:new_features) do
      add :name, :string, null: false
      add :config, :jsonb, default: "{}"
      add :enabled, :boolean, default: false
      
      timestamps()
    end
    
    # Complex migration logic tested in sandbox
    execute &migrate_existing_data/0
  end
  
  def down do
    drop table(:new_features)
  end
  
  defp migrate_existing_data do
    # This runs in sandbox first during development
    # Apex ensures it's safe before actual migration
  end
end
```

### Sandbox Testing

```elixir
defmodule MyApp.SandboxTest do
  use MyApp.DataCase
  use Apex.Ecto.SandboxTest
  
  describe "complex data operations" do
    test "bulk update performance", %{sandbox: sandbox} do
      # Run in isolated transaction
      apex_transaction sandbox do
        # Insert test data
        insert_list(1000, :product)
        
        # Profile the operation
        {time, result} = apex_profile do
          Products.bulk_update_prices(1.1)
        end
        
        assert time < 1000  # milliseconds
        assert result.updated_count == 1000
        
        # Transaction automatically rolled back
      end
    end
  end
end
```

## OTP Integration

### GenServer Integration

```elixir
defmodule MyApp.Worker do
  use GenServer
  use Apex.OTP.GenServer
  
  # Automatically adds development instrumentation
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(opts) do
    # In development, state is automatically tracked
    {:ok, %{opts: opts, jobs: []}}
  end
  
  @impl true
  def handle_call(:get_state, _from, state) do
    # Apex adds introspection in development
    {:reply, state, state}
  end
  
  @impl true
  def handle_cast({:add_job, job}, state) do
    # Apex can intercept and profile this
    new_state = %{state | jobs: [job | state.jobs]}
    {:noreply, new_state}
  end
  
  # Development mode helpers
  if Mix.env() == :dev do
    def inspect_state do
      Apex.OTP.inspect_process(__MODULE__)
    end
    
    def modify_state(fun) do
      Apex.OTP.modify_state(__MODULE__, fun)
    end
  end
end
```

### Supervisor Integration

```elixir
defmodule MyApp.Supervisor do
  use Supervisor
  use Apex.OTP.Supervisor
  
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  @impl true
  def init(_opts) do
    children = [
      # Regular children
      {MyApp.Worker, []},
      {MyApp.Cache, []},
      
      # Apex monitoring (development only)
      apex_child(:monitor, MyApp),
      apex_child(:profiler, MyApp.Worker)
    ]
    
    # Apex adds supervision tree visualization in dev
    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

### Application Integration

```elixir
defmodule MyApp.Application do
  use Application
  use Apex.OTP.Application
  
  @impl true
  def start(_type, _args) do
    # Configure Apex based on environment
    apex_config = [
      mode: apex_mode(),
      features: apex_features(),
      integrations: [:phoenix, :ecto]
    ]
    
    children = [
      # Start Apex first if enabled
      apex_supervisor(apex_config),
      
      # Your application components
      MyApp.Repo,
      MyAppWeb.Endpoint,
      MyApp.Supervisor
    ]
    
    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
  
  defp apex_mode do
    case Mix.env() do
      :prod -> :isolation
      :dev -> :development
      :test -> :hybrid
    end
  end
end
```

## Testing Integration

### ExUnit Integration

```elixir
# test/test_helper.exs
ExUnit.start()

# Configure Apex for testing
Apex.Test.configure(
  mode: :hybrid,
  features: [:profiling, :debugging],
  sandbox: :automatic
)
```

### Test Case Helpers

```elixir
defmodule MyApp.ApexCase do
  use ExUnit.CaseTemplate
  
  using do
    quote do
      use Apex.Test
      
      # Automatic sandbox per test
      setup :apex_sandbox
      
      # Performance assertions
      import Apex.Test.Assertions
      
      # Debugging helpers
      import Apex.Test.Debug
    end
  end
  
  setup tags do
    # Configure mode based on tags
    mode = case tags do
      %{isolation: true} -> :isolation
      %{integration: true} -> :hybrid
      _ -> :development
    end
    
    {:ok, apex_mode: mode}
  end
end
```

### Property-Based Testing

```elixir
defmodule MyApp.PropertyTest do
  use ExUnit.Case
  use ExUnitProperties
  use Apex.Test.Properties
  
  property "concurrent operations are safe" do
    check all operations <- list_of(operation_generator()),
              max_runs: 100 do
      
      # Run in isolated sandbox
      apex_sandbox :isolation do
        # Execute operations concurrently
        results = apex_concurrent(operations)
        
        # Verify invariants
        assert_invariants_hold(results)
      end
    end
  end
  
  # Apex provides generators for common patterns
  defp operation_generator do
    apex_gen do
      one_of([
        {:create, apex_gen(:entity)},
        {:update, apex_gen(:id), apex_gen(:changes)},
        {:delete, apex_gen(:id)}
      ])
    end
  end
end
```

## Framework Adapters

### Plug Integration

```elixir
defmodule Apex.Plug do
  @behaviour Plug
  
  def init(opts) do
    mode = Keyword.get(opts, :mode, :development)
    features = Keyword.get(opts, :features, [])
    
    %{
      mode: mode,
      features: MapSet.new(features),
      config: Apex.Modes.config(mode)
    }
  end
  
  def call(conn, %{mode: mode} = opts) do
    if enabled?(conn, opts) do
      conn
      |> put_apex_mode(mode)
      |> attach_apex_features(opts.features)
      |> add_apex_headers()
    else
      conn
    end
  end
  
  defp enabled?(conn, opts) do
    apex_enabled?() and authorized?(conn, opts)
  end
end
```

### Absinthe Integration

```elixir
defmodule MyAppWeb.Schema do
  use Absinthe.Schema
  use Apex.Absinthe
  
  # Add development introspection
  if Mix.env() == :dev do
    apex_introspection do
      field :sandbox_info
      field :performance_metrics
      field :active_experiments
    end
  end
  
  query do
    field :products, list_of(:product) do
      # Automatic profiling in development
      apex_profile()
      
      resolve &Resolvers.list_products/3
    end
  end
  
  mutation do
    field :create_product, :product do
      arg :input, non_null(:product_input)
      
      # Sandbox testing in development
      apex_sandbox(:hybrid)
      
      resolve &Resolvers.create_product/3
    end
  end
end
```

### Broadway Integration

```elixir
defmodule MyApp.Pipeline do
  use Broadway
  use Apex.Broadway
  
  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {BroadwayKafka.Producer, [
          hosts: [localhost: 9092],
          group_id: "my_app",
          topics: ["events"]
        ]}
      ],
      processors: [
        default: [
          concurrency: 10,
          # Apex monitoring in development
          apex_monitor: Mix.env() == :dev
        ]
      ]
    )
  end
  
  @impl true
  def handle_message(_, message, _) do
    # Automatic profiling and debugging in dev
    apex_trace message do
      data = decode_message(message.data)
      process_event(data)
    end
    
    message
  end
  
  if Mix.env() == :dev do
    def inspect_pipeline do
      Apex.Broadway.inspect(__MODULE__)
    end
  end
end
```

## Custom Integration

### Creating Your Own Integration

```elixir
defmodule MyLibrary.Apex do
  @moduledoc """
  Apex integration for MyLibrary.
  """
  
  defmacro __using__(opts) do
    quote do
      @apex_opts unquote(opts)
      @before_compile MyLibrary.Apex
      
      # Add compile-time hooks
      Module.register_attribute(__MODULE__, :apex_profile, accumulate: true)
      Module.register_attribute(__MODULE__, :apex_sandbox, accumulate: true)
    end
  end
  
  defmacro __before_compile__(_env) do
    quote do
      if Apex.enabled?() do
        # Add runtime hooks
        def __apex_info__ do
          %{
            module: __MODULE__,
            opts: @apex_opts,
            profiles: @apex_profile,
            sandboxes: @apex_sandbox
          }
        end
      end
    end
  end
  
  # Integration API
  def profile(module, function, args) do
    if Apex.enabled?() and Apex.mode() == :development do
      Apex.Performance.profile(module, function, args)
    else
      apply(module, function, args)
    end
  end
end
```

### Integration Best Practices

```elixir
defmodule Apex.Integration.BestPractices do
  @moduledoc """
  Guidelines for creating Apex integrations.
  """
  
  # 1. Always check if Apex is enabled
  def conditional_feature do
    if Apex.enabled?() do
      # Add Apex features
    else
      # Normal behavior
    end
  end
  
  # 2. Respect operational modes
  def mode_aware_behavior do
    case Apex.mode() do
      :isolation -> restricted_behavior()
      :development -> unrestricted_behavior()
      :hybrid -> check_permissions_first()
    end
  end
  
  # 3. Use compile-time configuration when possible
  if Application.compile_env(:apex, :enabled, false) do
    def expensive_feature, do: :enabled
  else
    def expensive_feature, do: :disabled
  end
  
  # 4. Provide escape hatches
  def with_apex_disabled(fun) do
    Apex.disable_temporarily(fun)
  end
  
  # 5. Add telemetry
  def instrumented_operation do
    :telemetry.span(
      [:apex, :integration, :operation],
      %{},
      fn ->
        result = do_operation()
        {result, %{}}
      end
    )
  end
end
```

## Migration Guide

### From Existing Sandbox Solution

```elixir
# Old sandbox code
defmodule OldSandbox do
  def run_isolated(code) do
    # Simple isolation
  end
end

# Migrated to Apex
defmodule NewSandbox do
  def run_isolated(code) do
    {:ok, sandbox} = Apex.create(
      UUID.uuid4(),
      code,
      mode: :isolation,
      compatible: :legacy_api
    )
    
    Apex.execute(sandbox, :main, [])
  end
end
```

### Gradual Adoption

```elixir
defmodule MyApp.MigrationStrategy do
  # Phase 1: Add Apex alongside existing code
  def phase1 do
    # Keep existing code
    MyApp.existing_feature()
    
    # Add Apex features optionally
    if feature_flag?(:apex_enabled) do
      Apex.attach(MyApp, mode: :development)
    end
  end
  
  # Phase 2: Default to Apex with fallback
  def phase2 do
    try do
      Apex.create("feature", MyModule, mode: :hybrid)
    rescue
      _ -> MyApp.existing_feature()
    end
  end
  
  # Phase 3: Full Apex adoption
  def phase3 do
    Apex.create("feature", MyModule, 
      mode: production_mode(),
      migration: :complete
    )
  end
end
```

## Next Steps

1. Review [Security Model](06_security_model.md) for security considerations
2. See [Development Tools](07_development_tools.md) for tool usage
3. Follow [Implementation Guide](08_implementation_guide.md) for deployment
4. Check [Performance Guide](09_performance_guide.md) for optimization