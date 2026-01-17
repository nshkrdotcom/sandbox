defmodule Sandbox.Config do
  @moduledoc """
  Centralized configuration for sandbox service names and ETS tables.

  This module merges defaults with application environment overrides and
  per-call overrides to enable isolated test runtimes.
  """

  @default_table_names %{
    sandboxes: :sandboxes,
    sandbox_monitors: :sandbox_monitors,
    module_versions: :apex_module_versions,
    isolation_contexts: :sandbox_isolation_contexts,
    sandbox_registry: :sandbox_registry,
    sandbox_modules: :sandbox_modules,
    sandbox_resources: :sandbox_resources,
    sandbox_security: :sandbox_security
  }

  @default_service_names %{
    manager: Sandbox.Manager,
    module_version_manager: Sandbox.ModuleVersionManager,
    process_isolator: Sandbox.ProcessIsolator,
    resource_monitor: Sandbox.ResourceMonitor,
    security_controller: Sandbox.SecurityController,
    file_watcher: Sandbox.FileWatcher,
    state_preservation: Sandbox.StatePreservation
  }

  @default_table_prefixes %{
    module_registry: "sandbox_modules",
    virtual_code: "sandbox_code"
  }

  def table_names(opts \\ []) do
    env = Application.get_env(:sandbox, :table_names, %{})
    override = Keyword.get(opts, :table_names, %{})

    @default_table_names
    |> Map.merge(env)
    |> Map.merge(override)
  end

  def table_name(key, opts \\ []) do
    Map.fetch!(table_names(opts), key)
  end

  def service_names(opts \\ []) do
    env = Application.get_env(:sandbox, :services, %{})
    override = Keyword.get(opts, :services, %{})

    @default_service_names
    |> Map.merge(env)
    |> Map.merge(override)
  end

  def service_name(key, opts \\ []) do
    Map.fetch!(service_names(opts), key)
  end

  def table_prefixes(opts \\ []) do
    env = Application.get_env(:sandbox, :table_prefixes, %{})
    override = Keyword.get(opts, :table_prefixes, %{})

    @default_table_prefixes
    |> Map.merge(env)
    |> Map.merge(override)
  end

  def table_prefix(key, opts \\ []) do
    Map.fetch!(table_prefixes(opts), key)
  end

  def cleanup_ets_on_stop?(state \\ nil) do
    case state do
      %{cleanup_ets_on_stop: value} -> value
      _ -> Application.get_env(:sandbox, :cleanup_ets_on_stop, false)
    end
  end
end
