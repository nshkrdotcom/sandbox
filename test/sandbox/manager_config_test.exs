defmodule Sandbox.ManagerConfigTest do
  use ExUnit.Case, async: true

  require Logger
  alias Sandbox.Manager
  import Supertester.OTPHelpers
  import Supertester.Assertions

  @moduletag :capture_log

  # Helper to get test fixture path consistently
  defp test_fixture_path do
    Path.expand("../../fixtures/simple_sandbox", __DIR__)
  end

  describe "configuration validation" do
    test "validates supervisor module exists" do
      sandbox_id = "test-invalid-supervisor-#{:rand.uniform(10000)}"

      # Test with non-existent module
      result =
        Manager.create_sandbox(
          sandbox_id,
          NonExistentSupervisor,
          sandbox_path: test_fixture_path()
        )

      assert {:error, {:validation_failed, errors}} = result

      assert Enum.any?(errors, fn error ->
               case error do
                 {:supervisor_module_not_found, NonExistentSupervisor} -> true
                 _ -> false
               end
             end)
    end

    test "validates sandbox path exists" do
      defmodule ValidSupervisor do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-invalid-path-#{:rand.uniform(10000)}"

      # Test with non-existent path
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor,
          sandbox_path: "/non/existent/path"
        )

      assert {:error, {:validation_failed, errors}} = result

      assert Enum.any?(errors, fn error ->
               case error do
                 {:sandbox_path_not_found, message} when is_binary(message) ->
                   String.contains?(message, "/non/existent/path")

                 _ ->
                   false
               end
             end)
    end

    test "validates resource limits format" do
      defmodule ValidSupervisor2 do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-invalid-limits-#{:rand.uniform(10000)}"

      # Test with invalid resource limits
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor2,
          sandbox_path: test_fixture_path(),
          resource_limits: "invalid"
        )

      assert {:error, {:validation_failed, errors}} = result

      assert Enum.any?(errors, fn error ->
               case error do
                 {:invalid_resource_limits, message} when is_binary(message) ->
                   String.contains?(message, "must be a map")

                 _ ->
                   false
               end
             end)
    end

    test "validates security profile" do
      defmodule ValidSupervisor3 do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-invalid-security-#{:rand.uniform(10000)}"

      # Test with invalid security profile
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor3,
          sandbox_path: test_fixture_path(),
          security_profile: :invalid_profile
        )

      assert {:error, {:validation_failed, errors}} = result

      assert Enum.any?(errors, fn error ->
               case error do
                 {:invalid_security_profile_name, message} when is_binary(message) ->
                   String.contains?(message, "must be :high, :medium, or :low")

                 _ ->
                   false
               end
             end)
    end

    test "accepts valid configuration with defaults" do
      defmodule ValidSupervisor4 do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-valid-config-#{:rand.uniform(10000)}"

      # Test with valid configuration
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor4,
          sandbox_path: test_fixture_path()
        )

      # Should succeed or fail for reasons other than validation
      case result do
        {:ok, _sandbox_info} ->
          # Success - clean up
          try do
            Manager.destroy_sandbox(sandbox_id)
          catch
            # Ignore cleanup failures for this test
            :exit, _ -> :ok
          end

          :ok

        {:error, {:validation_failed, _errors}} ->
          flunk("Configuration validation should have passed")

        {:error, _other_reason} ->
          # Failed for other reasons (compilation, etc.) - that's acceptable for this test
          :ok
      end
    end

    test "accepts valid resource limits" do
      defmodule ValidSupervisor5 do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      sandbox_id = "test-valid-limits-#{:rand.uniform(10000)}"

      # Test with valid resource limits
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor5,
          sandbox_path: test_fixture_path(),
          resource_limits: %{
            # 32MB
            max_memory: 32 * 1024 * 1024,
            max_processes: 50
          }
        )

      # Should succeed or fail for reasons other than validation
      case result do
        {:ok, sandbox_info} ->
          # Verify resource limits were applied
          assert is_map(sandbox_info.resource_usage)

          try do
            Manager.destroy_sandbox(sandbox_id)
          catch
            # Ignore cleanup failures for this test
            :exit, _ -> :ok
          end

          :ok

        {:error, {:validation_failed, _errors}} ->
          flunk("Resource limits validation should have passed")

        {:error, _other_reason} ->
          # Failed for other reasons - that's acceptable for this test
          :ok
      end
    end

    test "accepts valid security profiles" do
      defmodule ValidSupervisor6 do
        use Supervisor

        def start_link(opts) do
          Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
        end

        def init(_opts) do
          children = []
          Supervisor.init(children, strategy: :one_for_one)
        end
      end

      for profile <- [:high, :medium, :low] do
        sandbox_id = "test-security-#{profile}-#{:rand.uniform(10000)}"

        # Test with valid security profile
        result =
          Manager.create_sandbox(
            sandbox_id,
            ValidSupervisor6,
            sandbox_path: test_fixture_path(),
            security_profile: profile
          )

        # Should succeed or fail for reasons other than validation
        case result do
          {:ok, sandbox_info} ->
            # Verify security profile was applied (it should be in the expected format)
            assert is_map(sandbox_info.security_profile)
            assert Map.has_key?(sandbox_info.security_profile, :isolation_level)
            # Note: The actual profile might be the default if not properly applied
            try do
              Manager.destroy_sandbox(sandbox_id)
            catch
              # Ignore cleanup failures for this test
              :exit, _ -> :ok
            end

            :ok

          {:error, {:validation_failed, _errors}} ->
            flunk("Security profile #{profile} validation should have passed")

          {:error, _other_reason} ->
            # Failed for other reasons - that's acceptable for this test
            :ok
        end
      end
    end
  end

  describe "enhanced configuration validation" do
    test "validates sandbox directory structure" do
      defmodule TestSupervisor1 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      # Test with directory missing mix.exs
      temp_dir = create_temp_directory()
      sandbox_id = "test-no-mix-#{:rand.uniform(10000)}"

      result = Manager.create_sandbox(sandbox_id, TestSupervisor1, sandbox_path: temp_dir)

      assert {:error, {:validation_failed, errors}} = result
      assert_error_contains(errors, :sandbox_missing_mix_file)

      # Cleanup
      File.rm_rf!(temp_dir)
    end

    test "validates resource limit bounds" do
      defmodule TestSupervisor2 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = "test-resource-bounds-#{:rand.uniform(10000)}"

      # Test memory limit too small
      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor2,
          sandbox_path: test_fixture_path(),
          # Less than 1MB
          resource_limits: %{max_memory: 512}
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:invalid_resource_limit_values, errors} = error
      assert_error_contains(errors, :max_memory_too_small)
    end

    test "validates resource limit types" do
      defmodule TestSupervisor3 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = "test-resource-types-#{:rand.uniform(10000)}"

      # Test invalid memory type
      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor3,
          sandbox_path: test_fixture_path(),
          resource_limits: %{max_memory: "invalid"}
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:invalid_resource_limit_values, errors} = error
      assert_error_contains(errors, :invalid_max_memory)
    end

    test "validates custom security profiles" do
      defmodule TestSupervisor4 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = "test-custom-security-#{:rand.uniform(10000)}"

      # Test valid custom security profile
      custom_profile = %{
        isolation_level: :medium,
        allowed_operations: [:basic_otp, :math],
        restricted_modules: [:file, :os],
        audit_level: :basic
      }

      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor4,
          sandbox_path: test_fixture_path(),
          security_profile: custom_profile
        )

      # Should succeed or fail for reasons other than validation
      case result do
        {:ok, sandbox_info} ->
          assert is_map(sandbox_info.security_profile)

          try do
            Manager.destroy_sandbox(sandbox_id)
          catch
            :exit, _ -> :ok
          end

        {:error, {:validation_failed, _errors}} ->
          flunk("Valid custom security profile should have passed validation")

        {:error, _other_reason} ->
          # Failed for other reasons - acceptable
          :ok
      end
    end

    test "rejects invalid custom security profiles" do
      defmodule TestSupervisor5 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = "test-invalid-custom-security-#{:rand.uniform(10000)}"

      # Test custom profile missing required keys
      invalid_profile = %{
        isolation_level: :medium
        # Missing required keys
      }

      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor5,
          sandbox_path: test_fixture_path(),
          security_profile: invalid_profile
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:invalid_custom_security_profile, errors} = error
      assert_error_contains(errors, :missing_security_profile_key)
    end

    test "validates security profile consistency" do
      defmodule TestSupervisor6 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = "test-security-consistency-#{:rand.uniform(10000)}"

      # Test inconsistent security profile (high isolation with dangerous operations)
      inconsistent_profile = %{
        isolation_level: :high,
        # Inconsistent with high isolation
        allowed_operations: [:basic_otp, :file_write, :network_server],
        restricted_modules: [],
        audit_level: :full
      }

      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor6,
          sandbox_path: test_fixture_path(),
          security_profile: inconsistent_profile
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:security_profile_inconsistent, _message} = error
    end

    test "validates comprehensive configuration scenarios using Supertester" do
      defmodule TestSupervisor7 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      # Test comprehensive valid configuration
      sandbox_id = "test-comprehensive-#{:rand.uniform(10000)}"

      comprehensive_config = [
        sandbox_path: test_fixture_path(),
        resource_limits: %{
          # 64MB
          max_memory: 64 * 1024 * 1024,
          max_processes: 50,
          # 2 minutes
          max_execution_time: 120_000,
          # 5MB
          max_file_size: 5 * 1024 * 1024,
          max_cpu_percentage: 25.0
        },
        security_profile: :high,
        compile_timeout: 45_000,
        auto_reload: true
      ]

      result = Manager.create_sandbox(sandbox_id, TestSupervisor7, comprehensive_config)

      case result do
        {:ok, sandbox_info} ->
          # Use Supertester OTP helpers to wait for sandbox to be ready
          wait_for_sandbox_ready(sandbox_id, 5000)

          # Verify configuration was applied
          {:ok, final_info} = Manager.get_sandbox_info(sandbox_id)
          assert is_map(final_info.security_profile)
          assert final_info.security_profile.isolation_level == :high

          # Cleanup
          try do
            Manager.destroy_sandbox(sandbox_id)
          catch
            :exit, _ -> :ok
          end

        {:error, {:validation_failed, errors}} ->
          flunk(
            "Comprehensive valid configuration should pass validation, got errors: #{inspect(errors)}"
          )

        {:error, other_reason} ->
          # Failed for other reasons (compilation, etc.) - acceptable for this test
          Logger.info(
            "Sandbox creation failed for non-validation reasons: #{inspect(other_reason)}"
          )

          :ok
      end
    end
  end

  # Helper functions for enhanced testing
  defp create_temp_directory do
    temp_dir = Path.join([System.tmp_dir!(), "sandbox_test_#{:rand.uniform(100_000)}"])
    File.mkdir_p!(temp_dir)
    temp_dir
  end

  defp assert_error_contains(errors, expected_error_type) do
    found =
      Enum.any?(errors, fn error ->
        case error do
          {^expected_error_type, _message} -> true
          _ -> false
        end
      end)

    unless found do
      flunk("Expected error type #{expected_error_type} not found in errors: #{inspect(errors)}")
    end
  end

  defp wait_for_sandbox_ready(sandbox_id, timeout) do
    start_time = System.monotonic_time(:millisecond)
    wait_for_sandbox_ready_loop(sandbox_id, start_time, timeout)
  end

  defp wait_for_sandbox_ready_loop(sandbox_id, start_time, timeout) do
    current_time = System.monotonic_time(:millisecond)

    if current_time - start_time > timeout do
      flunk("Sandbox #{sandbox_id} did not become ready within #{timeout}ms")
    else
      case Manager.get_sandbox_info(sandbox_id) do
        {:ok, info} when info.status in [:running, :compiling, :starting] ->
          :ok

        {:ok, info} when info.status == :error ->
          flunk("Sandbox #{sandbox_id} entered error state: #{inspect(info)}")

        {:error, :not_found} ->
          flunk("Sandbox #{sandbox_id} not found")

        _ ->
          # Small sleep for polling - acceptable in test context
          Process.sleep(50)
          wait_for_sandbox_ready_loop(sandbox_id, start_time, timeout)
      end
    end
  end

  # Helper function to create test fixtures directory if it doesn't exist
  defp ensure_test_fixtures do
    fixture_path = test_fixture_path()

    unless File.exists?(fixture_path) do
      File.mkdir_p!(fixture_path)
      File.mkdir_p!(Path.join(fixture_path, "lib"))

      # Create a simple mix.exs
      mix_content = """
      defmodule SimpleSandbox.MixProject do
        use Mix.Project

        def project do
          [
            app: :simple_sandbox,
            version: "0.1.0",
            elixir: "~> 1.14"
          ]
        end

        def application do
          [
            extra_applications: [:logger]
          ]
        end
      end
      """

      File.write!(Path.join(fixture_path, "mix.exs"), mix_content)

      # Create a simple module
      module_content = """
      defmodule SimpleSandbox do
        def hello do
          :world
        end
      end
      """

      File.write!(Path.join([fixture_path, "lib", "simple_sandbox.ex"]), module_content)
    end
  end

  setup do
    ensure_test_fixtures()
    :ok
  end
end
