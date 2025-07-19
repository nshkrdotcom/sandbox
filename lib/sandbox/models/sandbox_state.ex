defmodule Sandbox.Models.SandboxState do
  @moduledoc """
  Data model for sandbox state management.

  This module defines the complete state structure for a sandbox instance,
  including status tracking, resource usage, and configuration.
  """

  @type t :: %__MODULE__{
          id: String.t(),
          status: sandbox_status(),
          app_name: atom(),
          supervisor_module: atom(),
          app_pid: pid() | nil,
          supervisor_pid: pid() | nil,
          monitor_ref: reference() | nil,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          restart_count: non_neg_integer(),
          config: sandbox_config(),
          resource_usage: resource_usage(),
          security_profile: security_profile(),
          file_watcher_pid: pid() | nil,
          auto_reload_enabled: boolean(),
          compilation_artifacts: [String.t()]
        }

  @type sandbox_status ::
          :initializing
          | :compiling
          | :starting
          | :running
          | :reloading
          | :stopping
          | :stopped
          | :error

  @type sandbox_config :: %{
          sandbox_path: String.t(),
          compile_timeout: non_neg_integer(),
          resource_limits: resource_limits(),
          auto_reload: boolean(),
          state_migration_handler: function() | nil
        }

  @type resource_limits :: %{
          max_memory: non_neg_integer(),
          max_processes: non_neg_integer(),
          max_execution_time: non_neg_integer(),
          max_file_size: non_neg_integer(),
          max_cpu_percentage: float()
        }

  @type resource_usage :: %{
          current_memory: non_neg_integer(),
          current_processes: non_neg_integer(),
          cpu_usage: float(),
          uptime: non_neg_integer()
        }

  @type security_profile :: %{
          isolation_level: :high | :medium | :low,
          allowed_operations: [atom()],
          restricted_modules: [atom()],
          audit_level: :full | :basic | :none
        }

  defstruct [
    :id,
    :status,
    :app_name,
    :supervisor_module,
    :app_pid,
    :supervisor_pid,
    :monitor_ref,
    :created_at,
    :updated_at,
    :restart_count,
    :config,
    :resource_usage,
    :security_profile,
    :file_watcher_pid,
    :auto_reload_enabled,
    :compilation_artifacts
  ]

  @doc """
  Creates a new sandbox state with default values.
  """
  def new(id, supervisor_module) when is_binary(id) and is_atom(supervisor_module) do
    # Generate app name from supervisor module
    app_name = generate_app_name(id, supervisor_module)
    config = default_config()
    new(id, app_name, supervisor_module, config)
  end

  def new(id, supervisor_module, opts)
      when is_binary(id) and is_atom(supervisor_module) and is_list(opts) do
    # Generate app name from supervisor module
    app_name = generate_app_name(id, supervisor_module)
    config = build_config_from_opts(opts)
    new(id, app_name, supervisor_module, config)
  end

  def new(id, app_name, supervisor_module, config) do
    now = DateTime.utc_now()

    %__MODULE__{
      id: id,
      status: :initializing,
      app_name: app_name,
      supervisor_module: supervisor_module,
      app_pid: nil,
      supervisor_pid: nil,
      monitor_ref: nil,
      created_at: now,
      updated_at: now,
      restart_count: 0,
      config: config,
      resource_usage: default_resource_usage(),
      security_profile: Map.get(config, :security_profile, default_security_profile()),
      file_watcher_pid: nil,
      auto_reload_enabled: Map.get(config, :auto_reload, false),
      compilation_artifacts: []
    }
  end

  @doc """
  Updates the sandbox status and timestamp.
  """
  def update_status(%__MODULE__{} = state, new_status) do
    %{state | status: new_status, updated_at: DateTime.utc_now()}
  end

  @doc """
  Updates the sandbox with process information.
  """
  def update_processes(%__MODULE__{} = state, app_pid, supervisor_pid, monitor_ref) do
    %{
      state
      | app_pid: app_pid,
        supervisor_pid: supervisor_pid,
        monitor_ref: monitor_ref,
        updated_at: DateTime.utc_now()
    }
  end

  @doc """
  Increments the restart count.
  """
  def increment_restart_count(%__MODULE__{} = state) do
    %{state | restart_count: state.restart_count + 1, updated_at: DateTime.utc_now()}
  end

  @doc """
  Updates resource usage information.
  """
  def update_resource_usage(%__MODULE__{} = state, resource_usage) do
    %{state | resource_usage: resource_usage, updated_at: DateTime.utc_now()}
  end

  @doc """
  Updates multiple fields in the sandbox state.
  """
  def update(%__MODULE__{} = state, updates) when is_list(updates) do
    Enum.reduce(updates, %{state | updated_at: DateTime.utc_now()}, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end

  @doc """
  Converts sandbox state to a public info map.
  """
  def to_info(%__MODULE__{} = state) do
    %{
      id: state.id,
      status: state.status,
      app_name: state.app_name,
      supervisor_module: state.supervisor_module,
      app_pid: state.app_pid,
      supervisor_pid: state.supervisor_pid,
      created_at: state.created_at,
      updated_at: state.updated_at,
      restart_count: state.restart_count,
      resource_usage: state.resource_usage,
      security_profile: state.security_profile,
      auto_reload_enabled: state.auto_reload_enabled
    }
  end

  defp default_resource_usage do
    %{
      current_memory: 0,
      current_processes: 0,
      cpu_usage: 0.0,
      uptime: 0
    }
  end

  defp default_security_profile do
    %{
      isolation_level: :medium,
      allowed_operations: [:basic_otp, :math, :string],
      restricted_modules: [],
      audit_level: :basic
    }
  end

  defp generate_app_name(id, supervisor_module) do
    # Convert supervisor module to app name format
    _module_str = supervisor_module |> to_string() |> String.replace("Elixir.", "")
    sanitized_id = id |> String.replace("-", "_") |> String.replace(" ", "_")
    String.to_atom("sandbox_#{sanitized_id}")
  end

  defp default_config do
    %{
      sandbox_path: "/tmp/sandbox",
      compile_timeout: 30_000,
      resource_limits: default_resource_limits(),
      auto_reload: false,
      state_migration_handler: nil
    }
  end

  defp build_config_from_opts(opts) do
    default_config()
    |> Map.merge(Map.new(opts))
    |> update_security_profile_from_opts(opts)
  end

  defp update_security_profile_from_opts(config, opts) do
    case Keyword.get(opts, :security_profile) do
      nil -> config
      :high -> Map.put(config, :security_profile, high_security_profile())
      :medium -> Map.put(config, :security_profile, default_security_profile())
      :low -> Map.put(config, :security_profile, low_security_profile())
      custom when is_map(custom) -> Map.put(config, :security_profile, custom)
      _ -> config
    end
  end

  defp default_resource_limits do
    %{
      # 128MB
      max_memory: 128 * 1024 * 1024,
      max_processes: 100,
      # 5 minutes
      max_execution_time: 300_000,
      # 10MB
      max_file_size: 10 * 1024 * 1024,
      max_cpu_percentage: 50.0
    }
  end

  defp high_security_profile do
    %{
      isolation_level: :high,
      allowed_operations: [:basic_otp, :math, :string],
      restricted_modules: [:file, :os, :code, :system, :port, :node],
      audit_level: :full
    }
  end

  defp low_security_profile do
    %{
      isolation_level: :low,
      allowed_operations: [:all],
      restricted_modules: [],
      audit_level: :basic
    }
  end
end
