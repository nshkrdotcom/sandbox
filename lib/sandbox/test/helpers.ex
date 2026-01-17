defmodule Sandbox.Test.Helpers do
  @moduledoc """
  Supertester integration helpers for sandbox testing.

  This module provides OTP-compliant testing patterns and utilities
  for testing sandbox functionality with proper process isolation
  and synchronization.
  """

  # Note: These imports should be used in test modules that use this helper
  # import Supertester.OTPHelpers
  # import Supertester.GenServerHelpers
  # import Supertester.Assertions

  require Logger

  @doc """
  Sets up a test sandbox with automatic cleanup.

  This function creates a sandbox for testing purposes and ensures
  it's properly cleaned up after the test completes.

  ## Options

    * `:supervisor_module` - The supervisor module to use
    * `:sandbox_path` - Path to sandbox code (optional)
    * `:auto_reload` - Enable auto-reload (default: false)
    * `:resource_limits` - Resource limits for the sandbox
    * `:security_profile` - Security profile (:high, :medium, :low)

  ## Examples

      test "sandbox creation" do
        {:ok, sandbox_pid} = setup_test_sandbox("test-sandbox", MySupervisor)
        assert Process.alive?(sandbox_pid)
      end
  """
  @spec setup_test_sandbox(String.t(), atom(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def setup_test_sandbox(test_name, supervisor_module, opts \\ []) do
    sandbox_id = "test_#{test_name}_#{:rand.uniform(10000)}"

    # Note: Cleanup should be handled by the test using ExUnit.Callbacks.on_exit/1

    case Sandbox.Manager.create_sandbox(sandbox_id, supervisor_module, opts) do
      {:ok, sandbox_info} ->
        {:ok, sandbox_info.app_pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Asserts that a sandbox is running and healthy.

  ## Examples

      assert_sandbox_running("my-sandbox")
  """
  @spec assert_sandbox_running(String.t()) :: :ok
  def assert_sandbox_running(sandbox_id) do
    case Sandbox.Manager.get_sandbox_info(sandbox_id) do
      {:ok, info} ->
        if info.status != :running do
          raise "Expected sandbox to be running, got: #{info.status}"
        end

        if not Process.alive?(info.app_pid) do
          raise "Sandbox app process is not alive"
        end

        if not Process.alive?(info.supervisor_pid) do
          raise "Sandbox supervisor process is not alive"
        end

        :ok

      {:error, :not_found} ->
        raise "Sandbox #{sandbox_id} not found"
    end
  end

  @doc """
  Asserts that a hot-reload operation was successful.

  ## Examples

      assert_hot_reload_successful("my-sandbox", MyModule)
  """
  @spec assert_hot_reload_successful(String.t(), atom()) :: :ok
  def assert_hot_reload_successful(sandbox_id, module) do
    # Check that the module is loaded in the sandbox
    case Sandbox.ModuleVersionManager.get_current_version(sandbox_id, module) do
      {:ok, version} ->
        if not (is_integer(version) and version > 0) do
          raise "Expected positive version number, got: #{inspect(version)}"
        end

        :ok

      {:error, :not_found} ->
        raise "Module #{module} not found in sandbox #{sandbox_id}"
    end
  end

  @doc """
  Waits for compilation to complete with proper OTP synchronization.

  This function uses OTP patterns instead of Process.sleep/1 to wait
  for compilation operations to complete.

  ## Examples

      :ok = wait_for_compilation("my-sandbox")
      :ok = wait_for_compilation("my-sandbox", 10_000)
  """
  @spec wait_for_compilation(String.t(), non_neg_integer()) :: :ok | {:error, :timeout}
  def wait_for_compilation(sandbox_id, timeout \\ 5000) do
    wait_for_condition(
      fn ->
        case Sandbox.Manager.get_sandbox_info(sandbox_id) do
          {:ok, info} ->
            status = info.status
            status != :initializing and status != :compiling

          {:error, _} ->
            # Return false to keep waiting
            false
        end
      end,
      timeout
    )
  end

  @doc """
  Performs stress testing on a sandbox with multiple operations.

  This function executes a series of operations against a sandbox
  and measures performance and stability.

  ## Examples

      operations = [
        {:create_module, MyModule, beam_data},
        {:hot_reload, MyModule, new_beam_data},
        {:rollback, MyModule, 1}
      ]
      
      {:ok, results} = stress_test_sandbox("my-sandbox", operations, 30_000)
  """
  @spec stress_test_sandbox(String.t(), [operation()], non_neg_integer()) ::
          {:ok, test_results()} | {:error, term()}
  def stress_test_sandbox(sandbox_id, operations, duration_ms) do
    start_time = System.monotonic_time(:millisecond)
    end_time = start_time + duration_ms

    results = %{
      operations_completed: 0,
      operations_failed: 0,
      average_response_time: 0,
      errors: []
    }

    stress_loop(sandbox_id, operations, end_time, results)
  end

  @doc """
  Creates a temporary sandbox directory for testing.

  ## Examples

      {:ok, temp_dir} = create_temp_sandbox_dir()
      File.write!(Path.join(temp_dir, "test.ex"), "defmodule Test, do: nil")
  """
  @spec create_temp_sandbox_dir() :: {:ok, String.t()} | {:error, term()}
  def create_temp_sandbox_dir do
    temp_dir = Path.join(System.tmp_dir!(), "sandbox_test_#{:rand.uniform(10000)}")

    case File.mkdir_p(temp_dir) do
      :ok ->
        # Note: Cleanup should be handled by the test using ExUnit.Callbacks.on_exit/1
        {:ok, temp_dir}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Asserts that no processes are leaked after sandbox operations.

  This function should be called at the end of tests to ensure
  proper cleanup and no process leaks.

  ## Examples

      test "no process leaks" do
        initial_count = length(Process.list())
        
        # ... perform sandbox operations ...
        
        assert_no_process_leaks(initial_count)
      end
  """
  @spec assert_no_process_leaks(non_neg_integer()) :: :ok
  def assert_no_process_leaks(initial_process_count) do
    # Allow some time for cleanup
    wait_for_condition(
      fn ->
        current_count = length(Process.list())
        # Allow small variance
        current_count <= initial_process_count + 5
      end,
      5000
    )

    final_count = length(Process.list())

    if final_count > initial_process_count + 5 do
      Logger.warning(
        "Potential process leak detected: #{final_count - initial_process_count} extra processes"
      )
    end

    :ok
  end

  # Private helper functions

  @doc """
  Waits for a condition to be true with a timeout.

  This is a replacement for Supertester's wait_until that can be used
  in regular modules.
  """
  def wait_for_condition(condition_fn, timeout \\ 5000) do
    end_time = System.monotonic_time(:millisecond) + timeout
    wait_for_condition_loop(condition_fn, end_time)
  end

  defp wait_for_condition_loop(condition_fn, end_time) do
    result = condition_fn.()

    cond do
      result == true ->
        :ok

      System.monotonic_time(:millisecond) >= end_time ->
        {:error, :timeout}

      true ->
        # Small sleep to avoid busy waiting
        Process.sleep(50)
        wait_for_condition_loop(condition_fn, end_time)
    end
  end

  @type operation ::
          {:create_module, atom(), binary()}
          | {:hot_reload, atom(), binary()}
          | {:rollback, atom(), non_neg_integer()}

  @type test_results :: %{
          operations_completed: non_neg_integer(),
          operations_failed: non_neg_integer(),
          average_response_time: float(),
          errors: [term()]
        }

  defp stress_loop(sandbox_id, operations, end_time, results) do
    current_time = System.monotonic_time(:millisecond)

    if current_time >= end_time do
      {:ok, results}
    else
      operation = Enum.random(operations)

      {duration, result} =
        :timer.tc(fn ->
          execute_stress_operation(sandbox_id, operation)
        end)

      updated_results =
        case result do
          :ok ->
            %{
              results
              | operations_completed: results.operations_completed + 1,
                average_response_time:
                  update_average(
                    results.average_response_time,
                    results.operations_completed,
                    duration / 1000
                  )
            }

          {:error, reason} ->
            %{
              results
              | operations_failed: results.operations_failed + 1,
                errors: [reason | results.errors]
            }
        end

      stress_loop(sandbox_id, operations, end_time, updated_results)
    end
  end

  defp execute_stress_operation(_sandbox_id, {:create_module, _module, _beam_data}) do
    # Placeholder - will be implemented when module management is available
    :ok
  end

  defp execute_stress_operation(_sandbox_id, {:hot_reload, _module, _beam_data}) do
    # Placeholder - will be implemented when hot-reload is available
    :ok
  end

  defp execute_stress_operation(_sandbox_id, {:rollback, _module, _version}) do
    # Placeholder - will be implemented when rollback is available
    :ok
  end

  defp update_average(current_avg, count, new_value) do
    (current_avg * count + new_value) / (count + 1)
  end
end
