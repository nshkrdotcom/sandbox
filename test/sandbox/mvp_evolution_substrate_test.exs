defmodule Sandbox.MvpEvolutionSubstrateTest do
  use Sandbox.ManagerCase

  alias Sandbox.Manager
  alias Sandbox.ModuleTransformer

  defmodule RunSupervisor do
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    def init(_opts) do
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  defmodule ResourceSupervisor do
    use Supervisor

    def start_link(opts) do
      Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
    end

    def init(_opts) do
      children = [
        {Agent, fn -> :ok end}
      ]

      Supervisor.init(children, strategy: :one_for_one)
    end
  end

  setup do
    ensure_fixture_tree()
    :ok
  end

  defp create_sandbox(manager, supervisor) do
    sandbox_id = unique_id("mvp-sandbox")

    {:ok, _info} =
      Manager.create_sandbox(
        sandbox_id,
        supervisor,
        sandbox_path: fixture_path(),
        server: manager
      )

    on_exit(fn ->
      ExUnit.CaptureLog.capture_log(fn ->
        Manager.destroy_sandbox(sandbox_id, server: manager)
      end)
    end)

    sandbox_id
  end

  test "run returns ok result", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    result = Sandbox.run(sandbox_id, fn -> :pong end, server: manager)

    assert result == {:ok, :pong}
  end

  test "run returns timeout when execution exceeds limit", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    result =
      Sandbox.run(
        sandbox_id,
        fn ->
          receive do
          after
            5000 -> :done
          end
        end,
        timeout: 10,
        server: manager
      )

    assert result == {:error, :timeout}
  end

  test "run returns crash reason", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    result = Sandbox.run(sandbox_id, fn -> exit(:boom) end, server: manager)

    assert result == {:error, {:crashed, :boom}}
  end

  test "run returns sandbox_not_found for missing sandbox", %{manager: manager} do
    result = Sandbox.run("missing-sandbox", fn -> :ok end, server: manager)

    assert result == {:error, :sandbox_not_found}
  end

  test "resource_usage aggregates process tree", %{manager: manager} do
    sandbox_id = create_sandbox(manager, ResourceSupervisor)

    {:ok, usage} = Sandbox.resource_usage(sandbox_id, server: manager)

    assert usage.current_processes >= 2
  end

  test "resource_usage returns not_found for missing sandbox", %{manager: manager} do
    result = Sandbox.resource_usage("missing-sandbox", server: manager)

    assert result == {:error, :not_found}
  end

  test "loads compiled modules for execution", %{
    manager: manager,
    table_prefixes: table_prefixes
  } do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    {:ok, transformed} =
      ModuleTransformer.lookup_module_mapping(
        sandbox_id,
        SimpleSandbox,
        table_prefix: table_prefixes.module_registry
      )

    result = transformed.hello()

    assert result == :world
  end

  test "hot_reload_source keeps namespace prefix", %{
    manager: manager,
    table_prefixes: table_prefixes
  } do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    {:ok, original} =
      ModuleTransformer.lookup_module_mapping(
        sandbox_id,
        SimpleSandbox,
        table_prefix: table_prefixes.module_registry
      )

    source = """
    defmodule SimpleSandbox do
      def hello do
        :reloaded
      end
    end
    """

    {:ok, :hot_reloaded} = Sandbox.hot_reload_source(sandbox_id, source, server: manager)

    {:ok, reloaded} =
      ModuleTransformer.lookup_module_mapping(
        sandbox_id,
        SimpleSandbox,
        table_prefix: table_prefixes.module_registry
      )

    assert original == reloaded
  end

  test "hot_reload_source updates module behavior", %{
    manager: manager,
    table_prefixes: table_prefixes
  } do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    {:ok, transformed} =
      ModuleTransformer.lookup_module_mapping(
        sandbox_id,
        SimpleSandbox,
        table_prefix: table_prefixes.module_registry
      )

    source = """
    defmodule SimpleSandbox do
      def hello do
        :updated
      end
    end
    """

    {:ok, :hot_reloaded} = Sandbox.hot_reload_source(sandbox_id, source, server: manager)

    result = transformed.hello()

    assert result == :updated
  end

  test "hot_reload_source returns parse_failed on invalid source", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    result = Sandbox.hot_reload_source(sandbox_id, "defmodule Broken", server: manager)

    assert match?({:error, {:parse_failed, _}}, result)
  end

  test "batch_create returns per-sandbox results", %{manager: manager} do
    sandbox_id = unique_id("batch-create")

    configs = [
      {sandbox_id, RunSupervisor, [sandbox_path: fixture_path()]}
    ]

    results = Sandbox.batch_create(configs, server: manager)

    on_exit(fn ->
      ExUnit.CaptureLog.capture_log(fn ->
        Manager.destroy_sandbox(sandbox_id, server: manager)
      end)
    end)

    assert [{^sandbox_id, {:ok, _}}] = results
  end

  test "batch_destroy returns per-sandbox results", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    results = Sandbox.batch_destroy([sandbox_id], server: manager)

    assert results == [{sandbox_id, :ok}]
  end

  test "batch_run returns per-sandbox results", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    results = Sandbox.batch_run([sandbox_id], fn -> :pong end, server: manager)

    assert results == [{sandbox_id, {:ok, :pong}}]
  end

  test "batch_hot_reload returns per-sandbox results", %{manager: manager} do
    sandbox_id = create_sandbox(manager, RunSupervisor)

    source = """
    defmodule SimpleSandbox do
      def hello do
        :batch
      end
    end
    """

    results = Sandbox.batch_hot_reload([sandbox_id], source, server: manager)

    assert results == [{sandbox_id, {:ok, :hot_reloaded}}]
  end
end
