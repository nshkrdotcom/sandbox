defmodule PluginExample do
  @moduledoc """
  Example of using Sandbox to build a plugin system.
  
  This demonstrates how to load, update, and manage plugins
  in isolated sandboxes.
  """

  @doc """
  Loads a plugin from a directory.
  """
  def load_plugin(plugin_dir) do
    plugin_name = Path.basename(plugin_dir)
    sandbox_id = "plugin_#{plugin_name}"
    
    # Compile the plugin
    case Sandbox.compile_sandbox(plugin_dir) do
      {:ok, compile_info} ->
        # Extract plugin info from compiled app file
        plugin_info = extract_plugin_info(compile_info.app_file)
        
        # Create sandbox with plugin supervisor
        case Sandbox.create_sandbox(sandbox_id, plugin_info.app,
               supervisor_module: plugin_info.supervisor,
               sandbox_path: plugin_dir) do
          {:ok, sandbox} ->
            {:ok, %{
              id: sandbox_id,
              name: plugin_name,
              sandbox: sandbox,
              info: plugin_info
            }}
          
          error ->
            error
        end
      
      error ->
        error
    end
  end

  @doc """
  Updates a running plugin with new code.
  """
  def update_plugin(plugin_id, new_plugin_dir) do
    # Compile new version
    case Sandbox.compile_sandbox(new_plugin_dir) do
      {:ok, compile_info} ->
        # Hot reload each module
        results = 
          Enum.map(compile_info.beam_files, fn beam_file ->
            beam_data = File.read!(beam_file)
            module = extract_module_name(beam_file)
            
            case Sandbox.hot_reload(plugin_id, beam_data) do
              {:ok, :hot_reloaded} ->
                {:ok, module}
              error ->
                {:error, {module, error}}
            end
          end)
        
        # Check if all modules were updated successfully
        case Enum.filter(results, &match?({:error, _}, &1)) do
          [] ->
            {:ok, :all_modules_updated}
          errors ->
            {:error, {:partial_update, errors}}
        end
      
      error ->
        error
    end
  end

  @doc """
  Lists all loaded plugins.
  """
  def list_plugins do
    Sandbox.list_sandboxes()
    |> Enum.filter(fn sandbox -> 
      String.starts_with?(sandbox.id, "plugin_")
    end)
    |> Enum.map(fn sandbox ->
      %{
        id: sandbox.id,
        name: String.replace_prefix(sandbox.id, "plugin_", ""),
        status: sandbox.status,
        loaded_at: sandbox.created_at
      }
    end)
  end

  @doc """
  Unloads a plugin.
  """
  def unload_plugin(plugin_id) do
    Sandbox.destroy_sandbox(plugin_id)
  end

  @doc """
  Calls a function in a plugin.
  """
  def call_plugin(plugin_id, module, function, args) do
    case Sandbox.get_sandbox_pid(plugin_id) do
      {:ok, _pid} ->
        # The plugin is running, we can call the function
        try do
          apply(module, function, args)
        rescue
          error ->
            {:error, {:plugin_error, error}}
        end
      
      {:error, :not_found} ->
        {:error, :plugin_not_loaded}
    end
  end

  # Private helpers

  defp extract_plugin_info(nil), do: %{app: :unknown, supervisor: nil}
  
  defp extract_plugin_info(app_file) do
    # Read the .app file to extract plugin metadata
    case :file.consult(app_file) do
      {:ok, [{:application, app_name, props}]} ->
        %{
          app: app_name,
          supervisor: get_in(props, [:mod]) |> elem(0),
          version: props[:vsn],
          description: props[:description]
        }
      
      _ ->
        %{app: :unknown, supervisor: nil}
    end
  end

  defp extract_module_name(beam_file) do
    case :beam_lib.info(String.to_charlist(beam_file)) do
      info when is_list(info) ->
        Keyword.get(info, :module)
      _ ->
        nil
    end
  end
end

# Example plugin that could be loaded
defmodule ExamplePlugin.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(_opts) do
    children = [
      ExamplePlugin.Worker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule ExamplePlugin.Worker do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def process(data) do
    GenServer.call(__MODULE__, {:process, data})
  end

  @impl true
  def init(_opts) do
    {:ok, %{processed_count: 0}}
  end

  @impl true
  def handle_call({:process, data}, _from, state) do
    # Plugin-specific processing logic
    result = String.upcase(data)
    new_state = %{state | processed_count: state.processed_count + 1}
    
    {:reply, {:ok, result}, new_state}
  end
end