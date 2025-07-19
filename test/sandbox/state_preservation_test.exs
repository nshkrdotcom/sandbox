# Test GenServer for state preservation testing
defmodule StatePreservationTestGenServer do
  use GenServer

  def start_link(initial_state) do
    GenServer.start_link(__MODULE__, initial_state)
  end

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:set_counter, value}, state) do
    {:noreply, %{state | counter: value}}
  end

  @impl true
  def handle_cast({:update_state, new_state}, _state) do
    {:noreply, new_state}
  end
end

defmodule Sandbox.StatePreservationTest do
  use ExUnit.Case, async: true

  alias Sandbox.StatePreservation

  setup do
    # StatePreservation is already started by the application
    # Just ensure it's available
    pid = Process.whereis(StatePreservation)

    if pid do
      %{state_preservation: pid}
    else
      # Start it if not already running (shouldn't happen in normal tests)
      {:ok, pid} = StatePreservation.start_link()

      on_exit(fn ->
        if Process.alive?(pid) do
          GenServer.stop(pid)
        end
      end)

      %{state_preservation: pid}
    end
  end

  describe "capture_process_state/2" do
    test "captures GenServer state successfully" do
      # Start a test GenServer
      {:ok, test_pid} = start_test_genserver(%{counter: 0, name: "test"})

      # Capture its state
      assert {:ok, capture} = StatePreservation.capture_process_state(test_pid)

      assert %{
               pid: ^test_pid,
               module: StatePreservationTestGenServer,
               state: %{counter: 0, name: "test"},
               captured_at: %DateTime{},
               process_info: %{},
               supervisor_info: nil
             } = capture
    end

    test "handles dead processes gracefully" do
      # Create a process and kill it
      test_pid = spawn(fn -> :ok end)
      wait_for_process_exit(test_pid)

      assert {:error, :process_dead} = StatePreservation.capture_process_state(test_pid)
    end

    test "captures supervisor information when requested" do
      # Start a supervised GenServer
      {:ok, supervisor_pid} = start_test_supervisor()
      {:ok, child_pid} = start_supervised_genserver(supervisor_pid, %{data: "test"})

      opts = [preserve_supervisor_specs: true]
      assert {:ok, capture} = StatePreservation.capture_process_state(child_pid, opts)

      assert capture.supervisor_info != nil
      assert capture.supervisor_info.supervisor_pid == supervisor_pid
    end
  end

  describe "capture_module_states/2" do
    test "captures all processes using a specific module" do
      # Start multiple GenServers using the same module
      {:ok, pid1} = start_test_genserver(%{id: 1})
      {:ok, pid2} = start_test_genserver(%{id: 2})
      {:ok, pid3} = start_test_genserver(%{id: 3})

      assert {:ok, captures} =
               StatePreservation.capture_module_states(StatePreservationTestGenServer)

      assert length(captures) == 3
      captured_pids = Enum.map(captures, & &1.pid)
      assert pid1 in captured_pids
      assert pid2 in captured_pids
      assert pid3 in captured_pids
    end

    test "returns empty list when no processes use the module" do
      assert {:ok, []} = StatePreservation.capture_module_states(NonExistentModule)
    end
  end

  describe "validate_state_compatibility/2" do
    test "validates compatible map states" do
      old_state = %{counter: 1, name: "test"}
      new_state = %{counter: 2, name: "updated", extra: "field"}

      assert {:ok, :compatible} =
               StatePreservation.validate_state_compatibility(old_state, new_state)
    end

    test "detects incompatible states with missing keys" do
      old_state = %{counter: 1, name: "test", required: "field"}
      new_state = %{counter: 2, name: "updated"}

      assert {:error, {:missing_keys, [:required]}} =
               StatePreservation.validate_state_compatibility(old_state, new_state)
    end

    test "validates compatible tuple states" do
      old_state = {:ok, "data", 123}
      new_state = {:ok, "new_data", 456}

      assert {:ok, :compatible} =
               StatePreservation.validate_state_compatibility(old_state, new_state)
    end

    test "detects incompatible tuple sizes" do
      old_state = {:ok, "data"}
      new_state = {:ok, "data", "extra"}

      assert {:error, {:size_mismatch, 2, 3}} =
               StatePreservation.validate_state_compatibility(old_state, new_state)
    end
  end

  describe "restore_states/4" do
    test "restores states with default migration" do
      # Start test GenServers
      {:ok, pid1} = start_test_genserver(%{counter: 1})
      {:ok, pid2} = start_test_genserver(%{counter: 2})

      # Capture their states
      {:ok, captures} = StatePreservation.capture_module_states(StatePreservationTestGenServer)

      # Modify the states
      GenServer.cast(pid1, {:set_counter, 10})
      GenServer.cast(pid2, {:set_counter, 20})

      # Restore original states
      assert {:ok, :restored} = StatePreservation.restore_states(captures, 1, 2)

      # Verify states were restored
      assert %{counter: 1} = GenServer.call(pid1, :get_state)
      assert %{counter: 2} = GenServer.call(pid2, :get_state)
    end

    test "applies custom migration function" do
      {:ok, pid} = start_test_genserver(%{counter: 5})
      {:ok, [capture]} = StatePreservation.capture_module_states(StatePreservationTestGenServer)

      # Custom migration that doubles the counter
      migration_fn = fn old_state, _old_v, _new_v ->
        %{old_state | counter: old_state.counter * 2}
      end

      opts = [migration_function: migration_fn]
      assert {:ok, :restored} = StatePreservation.restore_states([capture], 1, 2, opts)

      # Verify migration was applied
      assert %{counter: 10} = GenServer.call(pid, :get_state)
    end

    test "handles migration failures with rollback" do
      {:ok, pid} = start_test_genserver(%{counter: 5})
      {:ok, [capture]} = StatePreservation.capture_module_states(StatePreservationTestGenServer)

      # Migration function that raises an error
      migration_fn = fn _old_state, _old_v, _new_v ->
        raise "Migration failed"
      end

      opts = [migration_function: migration_fn, rollback_on_failure: true]
      assert {:error, _} = StatePreservation.restore_states([capture], 1, 2, opts)

      # Verify original state was preserved due to rollback
      assert %{counter: 5} = GenServer.call(pid, :get_state)
    end
  end

  describe "migrate_supervisor_specs/3" do
    test "migrates supervisor child specifications" do
      {:ok, supervisor_pid} = start_test_supervisor()
      {:ok, _child_pid} = start_supervised_genserver(supervisor_pid, %{data: "test"})

      # This is a simplified test - in practice, you'd need to actually
      # hot-reload a module and verify the supervisor specs are updated
      assert {:ok, :migrated} =
               StatePreservation.migrate_supervisor_specs(
                 supervisor_pid,
                 StatePreservationTestGenServer
               )
    end

    test "handles dead supervisor gracefully" do
      supervisor_pid = spawn(fn -> :ok end)
      wait_for_process_exit(supervisor_pid)

      assert {:error, :supervisor_dead} =
               StatePreservation.migrate_supervisor_specs(
                 supervisor_pid,
                 StatePreservationTestGenServer
               )
    end
  end

  describe "preserve_and_restore/4" do
    test "completes full preservation cycle" do
      # Start test processes
      {:ok, pid1} = start_test_genserver(%{counter: 1, name: "first"})
      {:ok, pid2} = start_test_genserver(%{counter: 2, name: "second"})

      # Run complete preservation cycle
      assert {:ok, :completed} =
               StatePreservation.preserve_and_restore(StatePreservationTestGenServer, 1, 2)

      # Verify processes are still alive and functional
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
      assert %{counter: 1} = GenServer.call(pid1, :get_state)
      assert %{counter: 2} = GenServer.call(pid2, :get_state)
    end

    test "handles preservation cycle with custom migration" do
      {:ok, pid} = start_test_genserver(%{counter: 5, version: 1})

      # Migration that updates version field
      migration_fn = fn old_state, _old_v, new_v ->
        %{old_state | version: new_v}
      end

      opts = [migration_function: migration_fn]

      assert {:ok, :completed} =
               StatePreservation.preserve_and_restore(StatePreservationTestGenServer, 1, 2, opts)

      # Verify migration was applied
      state = GenServer.call(pid, :get_state)
      assert state.version == 2
      # Other fields preserved
      assert state.counter == 5
    end
  end

  # Helper functions for testing

  defp start_test_genserver(initial_state) do
    GenServer.start_link(StatePreservationTestGenServer, initial_state)
  end

  defp start_test_supervisor do
    Supervisor.start_link([], strategy: :one_for_one)
  end

  defp start_supervised_genserver(supervisor_pid, initial_state) do
    child_spec = %{
      id: StatePreservationTestGenServer,
      start: {StatePreservationTestGenServer, :start_link, [initial_state]},
      type: :worker
    }

    case Supervisor.start_child(supervisor_pid, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp wait_for_process_exit(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      1000 -> :timeout
    end
  end
end
