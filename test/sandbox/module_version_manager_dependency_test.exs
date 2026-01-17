defmodule Sandbox.StatePreservationSpy do
  use GenServer

  def start_link(test_pid, name) do
    GenServer.start_link(__MODULE__, test_pid, name: name)
  end

  @impl true
  def init(test_pid) do
    {:ok, test_pid}
  end

  @impl true
  def handle_call({:capture_module_states, module, _opts}, _from, test_pid) do
    send(test_pid, {:capture_module_states, module})
    {:reply, {:ok, []}, test_pid}
  end

  @impl true
  def handle_call(
        {:restore_states, _captured_states, _old_version, _new_version, _opts},
        _from,
        test_pid
      ) do
    send(test_pid, :restore_states)
    {:reply, {:ok, :restored}, test_pid}
  end
end

defmodule Sandbox.ModuleVersionManagerDependencyTest do
  use Sandbox.TestCase

  # Import only if needed later
  # import Supertester.OTPHelpers
  # import Supertester.GenServerHelpers
  # import Supertester.Assertions

  alias Sandbox.ModuleVersionManager

  setup do
    table_name = unique_atom("module_versions")
    manager_name = unique_atom("module_version_manager")

    cleanup_on_exit(fn ->
      if :ets.whereis(table_name) != :undefined do
        :ets.delete(table_name)
      end
    end)

    {:ok, pid} =
      setup_isolated_genserver(ModuleVersionManager, "module_version_manager",
        init_args: [table_name: table_name],
        name: manager_name
      )

    Process.unlink(pid)

    {:ok, %{manager: manager_name, table: table_name}}
  end

  describe "calculate_reload_order/1" do
    test "calculates correct order for simple dependency chain", %{manager: manager} do
      mod_c = Module.concat(["ReloadOrder", unique_id("C")])
      mod_b = Module.concat(["ReloadOrder", unique_id("B")])
      mod_a = Module.concat(["ReloadOrder", unique_id("A")])

      compile_modules_to_path([
        {mod_c, []},
        {mod_b, [mod_c]},
        {mod_a, [mod_b]}
      ])

      assert {:ok, order} =
               ModuleVersionManager.calculate_reload_order([mod_a, mod_b, mod_c],
                 server: manager
               )

      assert_dependency_order(order, %{
        mod_a => [mod_b],
        mod_b => [mod_c],
        mod_c => []
      })
    end

    test "detects circular dependencies", %{manager: manager} do
      mod_a = Module.concat(["ReloadCycle", unique_id("A")])
      mod_b = Module.concat(["ReloadCycle", unique_id("B")])

      compile_modules_to_path([
        {mod_a, [mod_b]},
        {mod_b, [mod_a]}
      ])

      assert {:error, {:circular_dependency, _cycles}} =
               ModuleVersionManager.calculate_reload_order([mod_a, mod_b], server: manager)
    end

    test "handles modules with no dependencies", %{manager: manager} do
      mod_a = Module.concat(["ReloadStandalone", unique_id("A")])
      mod_b = Module.concat(["ReloadStandalone", unique_id("B")])

      compile_modules_to_path([
        {mod_a, []},
        {mod_b, []}
      ])

      assert {:ok, order} =
               ModuleVersionManager.calculate_reload_order([mod_a, mod_b], server: manager)

      assert Enum.sort(order) == Enum.sort([mod_a, mod_b])
    end
  end

  describe "detect_circular_dependencies/1" do
    test "detects simple circular dependency", %{manager: manager} do
      dependency_graph = %{
        ModuleA => [ModuleB],
        ModuleB => [ModuleA]
      }

      assert {:error, {:circular_dependency, cycles}} =
               ModuleVersionManager.detect_circular_dependencies(dependency_graph,
                 server: manager
               )

      assert cycles != []
    end

    test "detects complex circular dependency", %{manager: manager} do
      dependency_graph = %{
        ModuleA => [ModuleB],
        ModuleB => [ModuleC],
        ModuleC => [ModuleA]
      }

      assert {:error, {:circular_dependency, cycles}} =
               ModuleVersionManager.detect_circular_dependencies(dependency_graph,
                 server: manager
               )

      assert cycles != []
    end

    test "returns no cycles for acyclic graph", %{manager: manager} do
      dependency_graph = %{
        ModuleA => [ModuleB, ModuleC],
        ModuleB => [ModuleD],
        ModuleC => [ModuleD],
        ModuleD => []
      }

      assert {:ok, :no_cycles} =
               ModuleVersionManager.detect_circular_dependencies(dependency_graph,
                 server: manager
               )
    end
  end

  describe "extract_beam_dependencies/1" do
    test "extracts imports, exports, and attributes from BEAM data", %{manager: manager} do
      # Use real BEAM data instead of mocks
      beam_data = create_real_beam_data()

      assert {:ok, dependencies} =
               ModuleVersionManager.extract_beam_dependencies(beam_data, server: manager)

      # Check the module name starts with TestBeamModule
      assert is_atom(dependencies.module)
      module_name = Atom.to_string(dependencies.module)
      assert String.starts_with?(module_name, "TestBeamModule")

      # Check that we have the expected fields
      assert is_list(dependencies.imports)
      assert is_list(dependencies.exports)
      assert is_map(dependencies.attributes)

      # Check exports - our test module has these functions
      exports = Enum.map(dependencies.exports, fn {func, _arity} -> func end)
      assert :public_func in exports
      assert :another_func in exports
      assert :init in exports

      # Check attributes
      assert dependencies.attributes[:behaviour] == [GenServer]
    end

    test "handles BEAM analysis errors gracefully", %{manager: manager} do
      # Test with actual invalid BEAM data
      beam_data = "invalid_beam_data"

      assert {:error, {:beam_analysis_failed, {:not_a_beam_file, _}}} =
               ModuleVersionManager.extract_beam_dependencies(beam_data, server: manager)
    end
  end

  describe "cascading_reload/3" do
    test "performs cascading reload in correct order", %{manager: manager} do
      sandbox_id = unique_id("cascade")

      mod_c = Module.concat(["Cascade", unique_id("C")])
      mod_b = Module.concat(["Cascade", unique_id("B")])
      mod_a = Module.concat(["Cascade", unique_id("A")])

      beam_c = define_module(mod_c, value: 1)
      beam_b = define_module(mod_b, depends_on: mod_c)
      beam_a = define_module(mod_a, depends_on: [mod_b, mod_c])

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_c, beam_c,
                 server: manager
               )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_b, beam_b,
                 server: manager
               )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_a, beam_a,
                 server: manager
               )

      drain_module_loaded_messages()

      assert {:ok, :reloaded} =
               ModuleVersionManager.cascading_reload(sandbox_id, [mod_a, mod_b, mod_c],
                 server: manager,
                 force_reload: true
               )

      loaded = collect_module_loaded(3)
      assert loaded == [mod_c, mod_b, mod_a]
    end

    test "skips missing modules during reload", %{manager: manager} do
      sandbox_id = unique_id("cascade-fail")
      bad_module = Module.concat(["Cascade", unique_id("Bad")])

      assert {:ok, :reloaded} =
               ModuleVersionManager.cascading_reload(sandbox_id, [bad_module],
                 server: manager,
                 force_reload: true
               )
    end
  end

  describe "parallel_reload/3" do
    test "performs parallel reload of independent modules", %{manager: manager} do
      sandbox_id = unique_id("parallel-independent")

      mod_a = Module.concat(["Parallel", unique_id("A")])
      mod_b = Module.concat(["Parallel", unique_id("B")])

      beam_a = define_module(mod_a, value: :a)
      beam_b = define_module(mod_b, value: :b)

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_a, beam_a,
                 server: manager
               )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_b, beam_b,
                 server: manager
               )

      drain_module_loaded_messages()

      assert {:ok, :reloaded} =
               ModuleVersionManager.parallel_reload(sandbox_id, [mod_a, mod_b],
                 server: manager,
                 force_reload: true
               )

      loaded = collect_module_loaded(2)
      assert Enum.sort(loaded) == Enum.sort([mod_a, mod_b])
    end

    test "respects dependency levels during parallel reload", %{manager: manager} do
      sandbox_id = unique_id("parallel-levels")

      mod_d = Module.concat(["Parallel", unique_id("D")])
      mod_b = Module.concat(["Parallel", unique_id("B")])
      mod_c = Module.concat(["Parallel", unique_id("C")])
      mod_a = Module.concat(["Parallel", unique_id("A")])

      beam_d = define_module(mod_d, value: :d)
      beam_b = define_module(mod_b, depends_on: mod_d)
      beam_c = define_module(mod_c, depends_on: mod_d)
      beam_a = define_module(mod_a, depends_on: mod_b)

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_d, beam_d,
                 server: manager
               )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_b, beam_b,
                 server: manager
               )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_c, beam_c,
                 server: manager
               )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(sandbox_id, mod_a, beam_a,
                 server: manager
               )

      drain_module_loaded_messages()

      assert {:ok, :reloaded} =
               ModuleVersionManager.parallel_reload(sandbox_id, [mod_a, mod_b, mod_c, mod_d],
                 server: manager,
                 force_reload: true
               )

      loaded = collect_module_loaded(4)

      assert_dependency_order(loaded, %{
        mod_a => [mod_b, mod_c],
        mod_b => [mod_d],
        mod_c => [mod_d],
        mod_d => []
      })
    end
  end

  describe "integration with state preservation" do
    test "cascading reload preserves state across dependent modules", %{manager: manager} do
      sandbox_id = unique_id("stateful")

      stateful_module = Module.concat(["Stateful", unique_id("Module")])
      dependent_module = Module.concat(["Stateful", unique_id("Dependent")])

      beam_v1 = define_stateful_module(stateful_module, 1)
      beam_dep = define_module(dependent_module, depends_on: stateful_module)

      {:ok, pid} =
        setup_isolated_genserver(stateful_module, "stateful_module", init_args: %{count: 1})

      assert %{count: 1} = stateful_module.get_state(pid)

      {:ok, 1} =
        ModuleVersionManager.register_module_version(sandbox_id, stateful_module, beam_v1,
          server: manager
        )

      assert {:ok, 1} =
               ModuleVersionManager.register_module_version(
                 sandbox_id,
                 dependent_module,
                 beam_dep,
                 server: manager
               )

      beam_v2 = define_stateful_module(stateful_module, 2)

      state_handler = fn state, _old_version, _new_version ->
        Map.put(state, :migrated, true)
      end

      assert {:ok, :hot_swapped} =
               ModuleVersionManager.hot_swap_module(sandbox_id, stateful_module, beam_v2,
                 server: manager,
                 coordinate_dependencies: true,
                 use_state_preservation: true,
                 state_handler: state_handler
               )

      assert %{count: 1, migrated: true} = stateful_module.get_state(pid)
    end

    test "hot swap uses state preservation server override", %{manager: manager} do
      sandbox_id = unique_id("state_preservation_override")
      stateful_module = Module.concat(["Stateful", unique_id("Override")])

      beam_v1 = define_stateful_module(stateful_module, 1)

      {:ok, pid} =
        setup_isolated_genserver(stateful_module, "stateful_module", init_args: %{count: 1})

      Process.unlink(pid)

      {:ok, 1} =
        ModuleVersionManager.register_module_version(sandbox_id, stateful_module, beam_v1,
          server: manager
        )

      beam_v2 = define_stateful_module(stateful_module, 2)

      spy_name = unique_atom("state_preservation_spy")
      {:ok, spy_pid} = Sandbox.StatePreservationSpy.start_link(self(), spy_name)
      Process.unlink(spy_pid)

      cleanup_on_exit(fn ->
        if Process.alive?(spy_pid) do
          GenServer.stop(spy_pid)
        end
      end)

      result =
        ModuleVersionManager.hot_swap_module(sandbox_id, stateful_module, beam_v2,
          server: manager,
          state_preservation_server: spy_name
        )

      capture_msg =
        receive do
          {:capture_module_states, ^stateful_module} = msg -> msg
        after
          1000 -> :timeout
        end

      restore_msg =
        receive do
          :restore_states = msg -> msg
        after
          1000 -> :timeout
        end

      assert {result, [capture_msg, restore_msg]} ==
               {{:ok, :hot_swapped}, [{:capture_module_states, stateful_module}, :restore_states]}
    end

    test "hot swap uses services map state preservation override", %{manager: manager} do
      sandbox_id = unique_id("state_preservation_services")
      stateful_module = Module.concat(["Stateful", unique_id("Services")])

      beam_v1 = define_stateful_module(stateful_module, 1)

      {:ok, pid} =
        setup_isolated_genserver(stateful_module, "stateful_module", init_args: %{count: 1})

      Process.unlink(pid)

      {:ok, 1} =
        ModuleVersionManager.register_module_version(sandbox_id, stateful_module, beam_v1,
          server: manager
        )

      beam_v2 = define_stateful_module(stateful_module, 2)

      spy_name = unique_atom("state_preservation_spy_services")
      {:ok, spy_pid} = Sandbox.StatePreservationSpy.start_link(self(), spy_name)
      Process.unlink(spy_pid)

      cleanup_on_exit(fn ->
        if Process.alive?(spy_pid) do
          GenServer.stop(spy_pid)
        end
      end)

      result =
        ModuleVersionManager.hot_swap_module(sandbox_id, stateful_module, beam_v2,
          server: manager,
          services: [state_preservation: spy_name]
        )

      capture_msg =
        receive do
          {:capture_module_states, ^stateful_module} = msg -> msg
        after
          1000 -> :timeout
        end

      restore_msg =
        receive do
          :restore_states = msg -> msg
        after
          1000 -> :timeout
        end

      assert {result, [capture_msg, restore_msg]} ==
               {{:ok, :hot_swapped}, [{:capture_module_states, stateful_module}, :restore_states]}
    end
  end

  # Helper functions

  # Helper functions for creating test data

  defp compile_modules_to_path(modules_with_deps) do
    dir = create_temp_dir("module_deps")

    files =
      Enum.map(modules_with_deps, fn {module, deps} ->
        filename = "module_#{System.unique_integer([:positive])}.ex"
        path = Path.join(dir, filename)
        File.write!(path, module_source(module, deps))
        path
      end)

    {:ok, _modules, _warnings} =
      Kernel.ParallelCompiler.compile_to_path(files, dir, return_diagnostics: true)

    Code.prepend_path(dir)

    cleanup_on_exit(fn ->
      Code.delete_path(dir)
      File.rm_rf!(dir)
    end)

    :ok
  end

  defp module_source(module, deps) do
    body =
      case deps do
        [] ->
          ":ok"

        _ ->
          calls = Enum.map(deps, fn dep -> "#{inspect(dep)}.value()" end)

          case calls do
            [single] -> single
            _ -> "[" <> Enum.join(calls, ", ") <> "]"
          end
      end

    """
    defmodule #{inspect(module)} do
      def value do
        #{body}
      end
    end
    """
  end

  defp create_real_beam_data do
    # Create actual BEAM data from a simple module with unique name
    module_name = :"TestBeamModule#{System.unique_integer([:positive])}"

    {:module, ^module_name, beam_data, _} =
      Module.create(
        module_name,
        quote do
          @behaviour GenServer

          import Enum
          import String

          def init(state), do: {:ok, state}
          def public_func(x), do: x + 1
          def another_func, do: :ok
        end,
        Macro.Env.location(__ENV__)
      )

    # Return the BEAM data
    beam_data
  end

  defp define_module(module, opts) do
    depends_on = Keyword.get(opts, :depends_on)
    value = Keyword.get(opts, :value, :ok)

    :persistent_term.put({:module_load_pid, module}, self())

    value_expr =
      case depends_on do
        nil ->
          quote do
            unquote(value)
          end

        dep when is_list(dep) ->
          quoted_calls = Enum.map(dep, fn mod -> quote(do: unquote(mod).value()) end)

          quote do
            [unquote_splicing(quoted_calls)]
          end

        dep ->
          quote do
            unquote(dep).value()
          end
      end

    {:module, ^module, beam_data, _} =
      Module.create(
        module,
        quote do
          @on_load :__on_load__
          def __on_load__ do
            pid = :persistent_term.get({:module_load_pid, __MODULE__}, nil)

            if is_pid(pid) do
              send(pid, {:module_loaded, __MODULE__})
            end

            :ok
          end

          def value do
            unquote(value_expr)
          end
        end,
        Macro.Env.location(__ENV__)
      )

    beam_data
  end

  defp define_stateful_module(module, version) do
    {:module, ^module, beam_data, _} =
      Module.create(
        module,
        quote do
          use GenServer

          def start_link(initial_state) do
            GenServer.start_link(__MODULE__, initial_state)
          end

          def get_state(pid) do
            GenServer.call(pid, :get_state)
          end

          @impl true
          def init(state) do
            {:ok, state}
          end

          @impl true
          def handle_call(:get_state, _from, state) do
            {:reply, state, state}
          end

          def version, do: unquote(version)
        end,
        Macro.Env.location(__ENV__)
      )

    beam_data
  end

  defp drain_module_loaded_messages do
    receive do
      {:module_loaded, _module} -> drain_module_loaded_messages()
    after
      0 -> :ok
    end
  end

  defp collect_module_loaded(count, timeout \\ 2000) when is_integer(count) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect_module_loaded(count, deadline, [])
  end

  defp do_collect_module_loaded(0, _deadline, acc), do: Enum.reverse(acc)

  defp do_collect_module_loaded(remaining, deadline, acc) do
    now = System.monotonic_time(:millisecond)
    remaining_ms = max(deadline - now, 0)

    receive do
      {:module_loaded, module} ->
        do_collect_module_loaded(remaining - 1, deadline, [module | acc])
    after
      remaining_ms ->
        flunk("Timed out waiting for module reload notifications")
    end
  end

  defp assert_dependency_order(order, dependencies) when is_list(order) do
    index = Map.new(Enum.with_index(order))

    Enum.each(dependencies, fn {module, deps} ->
      Enum.each(deps, fn dep ->
        assert index[dep] < index[module]
      end)
    end)
  end
end

# Test GenServer for dependency testing
defmodule DependencyTestGenServer do
  use GenServer
  use Supertester.TestableGenServer

  def start_link({module, initial_state}) do
    GenServer.start_link(__MODULE__, {module, initial_state})
  end

  def start_link(initial_state) when is_map(initial_state) do
    GenServer.start_link(__MODULE__, initial_state)
  end

  @impl true
  def init({module, state}) do
    # Store the module info for testing
    Process.put(:test_module, module)
    {:ok, state}
  end

  def init(state) when is_map(state) do
    # Fallback for when state is passed directly (for backward compatibility)
    Process.put(:test_module, __MODULE__)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_module, _from, state) do
    module = Process.get(:test_module)
    {:reply, module, state}
  end

  @impl true
  def handle_cast({:update_state, new_state}, _state) do
    {:noreply, new_state}
  end
end
