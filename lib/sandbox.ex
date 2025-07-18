defmodule Sandbox do
  @moduledoc """
  Sandbox provides isolated OTP application management with hot-reload capabilities.

  This library enables you to create, manage, and hot-reload isolated OTP applications
  (sandboxes) within your Elixir system. Each sandbox runs in complete isolation with
  its own supervision tree, making it perfect for:

  - Learning and experimenting with OTP patterns
  - Building plugin systems
  - Running untrusted code safely
  - Testing supervision strategies
  - Hot-reloading code without affecting the main application

  ## Features

  - **True Isolation**: Each sandbox has its own supervision tree and process hierarchy
  - **Hot Reload**: Update running sandboxes without restarting
  - **Version Management**: Track and rollback module versions
  - **Fault Tolerance**: Sandbox crashes don't affect the host application
  - **Resource Control**: Compile-time limits and process monitoring

  ## Quick Start

  Start the Sandbox system:

      children = [
        Sandbox
      ]
      
      Supervisor.start_link(children, strategy: :one_for_one)

  Create a sandbox:

      {:ok, sandbox} = Sandbox.create_sandbox("my-sandbox", MySupervisor)

  Hot-reload code:

      {:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", new_beam_data)

  Destroy a sandbox:

      :ok = Sandbox.destroy_sandbox("my-sandbox")
  """

  use Application

  @doc false
  def start(_type, _args) do
    children = [
      Sandbox.Manager,
      Sandbox.ModuleVersionManager
    ]

    opts = [strategy: :one_for_one, name: Sandbox.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Delegated API functions for convenience

  @doc """
  Creates a new sandbox with the specified ID and configuration.
  
  ## Arguments
  
    * `sandbox_id` - Unique identifier for the sandbox
    * `module_or_app` - Either a supervisor module or application name
    * `opts` - Options for sandbox creation
  
  ## Options
  
    * `:supervisor_module` - Supervisor module to use (if app name provided)
    * `:sandbox_path` - Path to sandbox code directory
    * `:compile_timeout` - Compilation timeout in milliseconds (default: 30000)
    * `:validate_beams` - Whether to validate BEAM files (default: true)
  
  ## Examples
  
      # Using a supervisor module
      {:ok, sandbox} = Sandbox.create_sandbox("test", MyApp.Supervisor)
      
      # Using an application name
      {:ok, sandbox} = Sandbox.create_sandbox("test", :my_app,
        supervisor_module: MyApp.Supervisor,
        sandbox_path: "/path/to/sandbox"
      )
  """
  defdelegate create_sandbox(sandbox_id, module_or_app, opts \\ []), 
    to: Sandbox.Manager

  @doc """
  Destroys a sandbox and cleans up all its resources.
  
  ## Examples
  
      :ok = Sandbox.destroy_sandbox("my-sandbox")
  """
  defdelegate destroy_sandbox(sandbox_id), to: Sandbox.Manager

  @doc """
  Restarts a sandbox with the same configuration.
  
  ## Examples
  
      {:ok, sandbox_info} = Sandbox.restart_sandbox("my-sandbox")
  """
  defdelegate restart_sandbox(sandbox_id), to: Sandbox.Manager

  @doc """
  Hot-reloads a module in a sandbox with new code.
  
  ## Arguments
  
    * `sandbox_id` - The sandbox to reload code in
    * `new_beam_data` - The compiled BEAM bytecode
    * `opts` - Options for hot reload
  
  ## Options
  
    * `:state_handler` - Function to handle state migration `(old_state, old_version, new_version) -> new_state`
  
  ## Examples
  
      # Simple hot reload
      {:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data)
      
      # With custom state migration
      {:ok, :hot_reloaded} = Sandbox.hot_reload("my-sandbox", beam_data,
        state_handler: fn old_state, _old_v, _new_v ->
          Map.put(old_state, :upgraded, true)
        end
      )
  """
  defdelegate hot_reload(sandbox_id, new_beam_data, opts \\ []), 
    to: Sandbox.Manager, 
    as: :hot_reload_sandbox

  @doc """
  Gets information about a specific sandbox.
  
  ## Examples
  
      {:ok, info} = Sandbox.get_sandbox_info("my-sandbox")
      info.status #=> :running
  """
  defdelegate get_sandbox_info(sandbox_id), to: Sandbox.Manager

  @doc """
  Lists all active sandboxes.
  
  ## Examples
  
      sandboxes = Sandbox.list_sandboxes()
      Enum.map(sandboxes, & &1.id)
  """
  defdelegate list_sandboxes(), to: Sandbox.Manager

  @doc """
  Gets the main process PID for a sandbox.
  
  ## Examples
  
      {:ok, pid} = Sandbox.get_sandbox_pid("my-sandbox")
  """
  defdelegate get_sandbox_pid(sandbox_id), to: Sandbox.Manager

  # Module version management

  @doc """
  Gets the current version of a module in a sandbox.
  
  ## Examples
  
      {:ok, 3} = Sandbox.get_module_version("my-sandbox", MyModule)
  """
  defdelegate get_module_version(sandbox_id, module), 
    to: Sandbox.ModuleVersionManager,
    as: :get_current_version

  @doc """
  Lists all versions of a module in a sandbox.
  
  ## Examples
  
      versions = Sandbox.list_module_versions("my-sandbox", MyModule)
      Enum.map(versions, & &1.version) #=> [3, 2, 1]
  """
  defdelegate list_module_versions(sandbox_id, module), 
    to: Sandbox.ModuleVersionManager

  @doc """
  Rolls back a module to a previous version.
  
  ## Examples
  
      {:ok, :rolled_back} = Sandbox.rollback_module("my-sandbox", MyModule, 2)
  """
  defdelegate rollback_module(sandbox_id, module, target_version), 
    to: Sandbox.ModuleVersionManager

  @doc """
  Gets the version history for a module.
  
  ## Examples
  
      history = Sandbox.get_version_history("my-sandbox", MyModule)
      history.current_version #=> 3
      history.total_versions #=> 3
  """
  defdelegate get_version_history(sandbox_id, module),
    to: Sandbox.ModuleVersionManager

  # Compilation utilities

  @doc """
  Compiles a sandbox directory in isolation.
  
  ## Examples
  
      {:ok, compile_info} = Sandbox.compile_sandbox("/path/to/sandbox")
      compile_info.beam_files #=> ["path/to/module1.beam", ...]
  """
  defdelegate compile_sandbox(sandbox_path, opts \\ []), 
    to: Sandbox.IsolatedCompiler

  @doc """
  Compiles a single Elixir file in isolation.
  
  ## Examples
  
      {:ok, compile_info} = Sandbox.compile_file("/path/to/file.ex")
  """
  defdelegate compile_file(file_path, opts \\ []), 
    to: Sandbox.IsolatedCompiler
end