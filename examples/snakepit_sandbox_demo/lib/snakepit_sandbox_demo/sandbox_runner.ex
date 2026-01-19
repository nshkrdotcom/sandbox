defmodule SnakepitSandboxDemo.SandboxRunner do
  @moduledoc "Sandbox lifecycle helpers for the Snakepit demo."

  alias SnakepitSandboxDemo.{SandboxModules, Store}

  @default_session_store_timeout_ms 2_000
  @default_session_store_poll_ms 50

  def snakepit_path do
    System.get_env("SNAKEPIT_PATH") || Path.join(Mix.Project.deps_path(), "snakepit")
  end

  def create_sandbox(sandbox_id, sandbox_path \\ snakepit_path()) do
    with {:ok, prepared_path} <- prepare_sandbox_source(sandbox_path) do
      result =
        Sandbox.create_sandbox(sandbox_id, SnakepitSandboxDemo.SandboxSupervisor,
          sandbox_path: prepared_path,
          security_profile: :low,
          resource_limits: %{max_cpu_percentage: 100.0},
          source_exclude_dirs: ["_build", "deps", "test", "lib/mix"],
          protocol_consolidation: :reconsolidate
        )

      cleanup_prepared_source(prepared_path)
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def start_snakepit(sandbox_id, opts \\ []) do
    configure_snakepit_env(opts)

    with :ok <- maybe_start_grpc_apps(opts),
         :ok <- maybe_configure_adapter_module(sandbox_id, opts),
         {:ok, app_module} <- SandboxModules.resolve_module(sandbox_id, Snakepit.Application),
         {:ok, session_store} <-
           SandboxModules.resolve_module(sandbox_id, Snakepit.Bridge.SessionStore),
         {:ok, start_result} <- Sandbox.run(sandbox_id, fn -> start_snakepit_app(app_module) end),
         {:ok, pid} <- unwrap_start_result(start_result),
         :ok <- wait_for_session_store(sandbox_id, session_store, opts) do
      Store.set_snakepit_pid(pid)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def stop_snakepit(_sandbox_id) do
    case Store.get_snakepit_pid() do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 5_000), else: :ok

      _ ->
        :ok
    end
  end

  def seed_sessions(sandbox_id, count) when is_integer(count) and count > 0 do
    with {:ok, session_store} <-
           SandboxModules.resolve_module(sandbox_id, Snakepit.Bridge.SessionStore),
         {:ok, created} <-
           Sandbox.run(sandbox_id, fn ->
             Enum.reduce(1..count, 0, fn index, acc ->
               session_id =
                 "sandbox_session_#{index}_#{System.unique_integer([:positive])}"

               case apply(session_store, :create_session, [session_id]) do
                 {:ok, _session} -> acc + 1
                 _ -> acc
               end
             end)
           end) do
      {:ok, created}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def seed_sessions(_sandbox_id, count) when is_integer(count), do: {:ok, 0}
  def seed_sessions(_sandbox_id, _count), do: {:error, :invalid_session_count}

  def destroy_sandbox(sandbox_id) do
    Sandbox.destroy_sandbox(sandbox_id)
  end

  defp configure_snakepit_env(opts) do
    env = %{
      pooling_enabled: Keyword.get(opts, :pooling_enabled, false),
      enable_otlp?: Keyword.get(opts, :enable_otlp?, false),
      cleanup_on_stop: Keyword.get(opts, :cleanup_on_stop, true),
      auto_install_python_deps: Keyword.get(opts, :auto_install_python_deps, false)
    }

    Enum.each(env, fn {key, value} ->
      Application.put_env(:snakepit, key, value)
    end)

    maybe_put_env(:bootstrap_project_root, Keyword.get(opts, :bootstrap_project_root))
    maybe_put_python_env_dir(Keyword.get(opts, :python_env_dir))
  end

  defp maybe_put_env(_key, nil), do: :ok
  defp maybe_put_env(key, value), do: Application.put_env(:snakepit, key, value)

  defp maybe_put_python_env_dir(nil), do: :ok

  defp maybe_put_python_env_dir(env_dir) do
    existing = Application.get_env(:snakepit, :python_packages, [])
    Application.put_env(:snakepit, :python_packages, Keyword.merge(existing, env_dir: env_dir))
  end

  defp maybe_start_grpc_apps(opts) do
    if Keyword.get(opts, :pooling_enabled, false) do
      case Application.ensure_all_started(:grpc) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, {:grpc_dependency_start_failed, reason}}
      end
    else
      :ok
    end
  end

  defp maybe_configure_adapter_module(sandbox_id, opts) do
    if Keyword.get(opts, :pooling_enabled, false) do
      adapter_source =
        Keyword.get(opts, :adapter_module, Snakepit.Adapters.GRPCPython)

      case SandboxModules.resolve_module(sandbox_id, adapter_source) do
        {:ok, adapter_module} ->
          Application.put_env(:snakepit, :adapter_module, adapter_module)
          :ok

        {:error, reason} ->
          {:error, {:adapter_module_unresolved, reason}}
      end
    else
      :ok
    end
  end

  defp prepare_sandbox_source(source_path) do
    unless File.dir?(source_path) do
      {:error, {:snakepit_path_not_found, source_path}}
    else
      temp_dir =
        Path.join(
          System.tmp_dir!(),
          "snakepit_sandbox_source_#{System.unique_integer([:positive])}"
        )

      with :ok <- File.mkdir_p(temp_dir),
           :ok <-
             copy_if_exists(Path.join(source_path, "mix.exs"), Path.join(temp_dir, "mix.exs")),
           :ok <- copy_dir_if_exists(source_path, temp_dir, "lib"),
           :ok <- copy_dir_if_exists(source_path, temp_dir, "config"),
           :ok <- copy_dir_if_exists(source_path, temp_dir, "priv") do
        {:ok, temp_dir}
      else
        {:error, reason} -> {:error, {:snakepit_path_prepare_failed, reason}}
      end
    end
  end

  defp copy_if_exists(source, destination) do
    cond do
      File.regular?(source) ->
        case File.copy(source, destination) do
          {:ok, _bytes} -> :ok
          {:error, reason} -> {:error, reason}
        end

      File.exists?(source) ->
        {:error, {:unexpected_path_type, source}}

      true ->
        :ok
    end
  end

  defp copy_dir_if_exists(base_path, temp_dir, dir_name) do
    source = Path.join(base_path, dir_name)
    destination = Path.join(temp_dir, dir_name)

    if File.dir?(source) do
      case File.cp_r(source, destination) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp cleanup_prepared_source(path) do
    if path && String.starts_with?(path, System.tmp_dir!()) do
      File.rm_rf(path)
    else
      :ok
    end
  end

  defp start_snakepit_app(app_module) do
    case apply(app_module, :start, [:normal, []]) do
      {:ok, pid} = ok ->
        Process.unlink(pid)
        ok

      other ->
        other
    end
  end

  defp unwrap_start_result({:ok, pid}) when is_pid(pid), do: {:ok, pid}
  defp unwrap_start_result({:error, reason}), do: {:error, {:snakepit_start_failed, reason}}
  defp unwrap_start_result(other), do: {:error, {:snakepit_start_failed, other}}

  defp wait_for_session_store(sandbox_id, session_store, opts) do
    timeout_ms = Keyword.get(opts, :session_store_timeout_ms, @default_session_store_timeout_ms)
    poll_ms = Keyword.get(opts, :session_store_poll_ms, @default_session_store_poll_ms)
    deadline_ms = System.monotonic_time(:millisecond) + timeout_ms

    do_wait_for_session_store(sandbox_id, session_store, poll_ms, deadline_ms)
  end

  defp do_wait_for_session_store(sandbox_id, session_store, poll_ms, deadline_ms) do
    case Sandbox.run(sandbox_id, fn -> Process.whereis(session_store) end) do
      {:ok, pid} when is_pid(pid) ->
        :ok

      {:ok, _} ->
        retry_wait(sandbox_id, session_store, poll_ms, deadline_ms, :session_store_not_running)

      {:error, reason} ->
        retry_wait(sandbox_id, session_store, poll_ms, deadline_ms, reason)
    end
  end

  defp retry_wait(sandbox_id, session_store, poll_ms, deadline_ms, reason) do
    if System.monotonic_time(:millisecond) >= deadline_ms do
      {:error, {:session_store_unavailable, reason}}
    else
      Process.sleep(poll_ms)
      do_wait_for_session_store(sandbox_id, session_store, poll_ms, deadline_ms)
    end
  end
end
