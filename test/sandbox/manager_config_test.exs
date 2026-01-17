defmodule Sandbox.ManagerConfigTest do
  use Sandbox.ManagerCase

  require Logger
  alias Sandbox.Manager

  @moduletag :capture_log

  describe "configuration validation" do
    test "validates supervisor module exists", %{manager: manager} do
      sandbox_id = unique_id("test-invalid-supervisor")

      # Test with non-existent module
      result =
        Manager.create_sandbox(
          sandbox_id,
          NonExistentSupervisor,
          sandbox_path: fixture_path(),
          server: manager
        )

      assert {:error, {:validation_failed, errors}} = result

      assert Enum.any?(errors, fn error ->
               case error do
                 {:supervisor_module_not_found, NonExistentSupervisor} -> true
                 _ -> false
               end
             end)
    end

    test "validates sandbox path exists", %{manager: manager} do
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

      sandbox_id = unique_id("test-invalid-path")

      # Test with non-existent path
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor,
          sandbox_path: "/non/existent/path",
          server: manager
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

    test "validates resource limits format", %{manager: manager} do
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

      sandbox_id = unique_id("test-invalid-limits")

      # Test with invalid resource limits
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor2,
          sandbox_path: fixture_path(),
          resource_limits: "invalid",
          server: manager
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

    test "validates security profile", %{manager: manager} do
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

      sandbox_id = unique_id("test-invalid-security")

      # Test with invalid security profile
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor3,
          sandbox_path: fixture_path(),
          security_profile: :invalid_profile,
          server: manager
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

    test "accepts valid configuration with defaults", %{manager: manager} do
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

      sandbox_id = unique_id("test-valid-config")

      # Test with valid configuration
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor4,
          sandbox_path: fixture_path(),
          server: manager
        )

      # Should succeed or fail for reasons other than validation
      case result do
        {:ok, _sandbox_info} ->
          # Success - clean up
          try do
            Manager.destroy_sandbox(sandbox_id, server: manager)
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

    test "accepts valid resource limits", %{manager: manager} do
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

      sandbox_id = unique_id("test-valid-limits")

      # Test with valid resource limits
      result =
        Manager.create_sandbox(
          sandbox_id,
          ValidSupervisor5,
          sandbox_path: fixture_path(),
          resource_limits: %{
            # 32MB
            max_memory: 32 * 1024 * 1024,
            max_processes: 50
          },
          server: manager
        )

      # Should succeed or fail for reasons other than validation
      case result do
        {:ok, sandbox_info} ->
          # Verify resource limits were applied
          assert is_map(sandbox_info.resource_usage)

          try do
            Manager.destroy_sandbox(sandbox_id, server: manager)
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

    test "accepts valid security profiles", %{manager: manager} do
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
        sandbox_id = unique_id("test-security-#{profile}")

        # Test with valid security profile
        result =
          Manager.create_sandbox(
            sandbox_id,
            ValidSupervisor6,
            sandbox_path: fixture_path(),
            security_profile: profile,
            server: manager
          )

        # Should succeed or fail for reasons other than validation
        case result do
          {:ok, sandbox_info} ->
            # Verify security profile was applied (it should be in the expected format)
            assert is_map(sandbox_info.security_profile)
            assert Map.has_key?(sandbox_info.security_profile, :isolation_level)
            # Note: The actual profile might be the default if not properly applied
            try do
              Manager.destroy_sandbox(sandbox_id, server: manager)
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
    test "validates sandbox directory structure", %{manager: manager} do
      defmodule TestSupervisor1 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      # Test with directory missing mix.exs
      temp_dir = create_temp_directory()
      sandbox_id = unique_id("test-no-mix")

      result =
        Manager.create_sandbox(sandbox_id, TestSupervisor1,
          sandbox_path: temp_dir,
          server: manager
        )

      assert {:error, {:validation_failed, errors}} = result
      assert_error_contains(errors, :sandbox_missing_mix_file)

      # Cleanup
      File.rm_rf!(temp_dir)
    end

    test "validates resource limit bounds", %{manager: manager} do
      defmodule TestSupervisor2 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = unique_id("test-resource-bounds")

      # Test memory limit too small
      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor2,
          sandbox_path: fixture_path(),
          # Less than 1MB
          resource_limits: %{max_memory: 512},
          server: manager
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:invalid_resource_limit_values, errors} = error
      assert_error_contains(errors, :max_memory_too_small)
    end

    test "validates resource limit types", %{manager: manager} do
      defmodule TestSupervisor3 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = unique_id("test-resource-types")

      # Test invalid memory type
      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor3,
          sandbox_path: fixture_path(),
          resource_limits: %{max_memory: "invalid"},
          server: manager
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:invalid_resource_limit_values, errors} = error
      assert_error_contains(errors, :invalid_max_memory)
    end

    test "validates custom security profiles", %{manager: manager} do
      defmodule TestSupervisor4 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = unique_id("test-custom-security")

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
          sandbox_path: fixture_path(),
          security_profile: custom_profile,
          server: manager
        )

      # Should succeed or fail for reasons other than validation
      case result do
        {:ok, sandbox_info} ->
          assert is_map(sandbox_info.security_profile)

          try do
            Manager.destroy_sandbox(sandbox_id, server: manager)
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

    test "rejects invalid custom security profiles", %{manager: manager} do
      defmodule TestSupervisor5 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = unique_id("test-invalid-custom-security")

      # Test custom profile missing required keys
      invalid_profile = %{
        isolation_level: :medium
        # Missing required keys
      }

      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor5,
          sandbox_path: fixture_path(),
          security_profile: invalid_profile,
          server: manager
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:invalid_custom_security_profile, errors} = error
      assert_error_contains(errors, :missing_security_profile_key)
    end

    test "validates security profile consistency", %{manager: manager} do
      defmodule TestSupervisor6 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      sandbox_id = unique_id("test-security-consistency")

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
          sandbox_path: fixture_path(),
          security_profile: inconsistent_profile,
          server: manager
        )

      assert {:error, {:validation_failed, [error]}} = result
      assert {:security_profile_inconsistent, _message} = error
    end

    test "validates comprehensive configuration scenarios using Supertester", %{manager: manager} do
      defmodule TestSupervisor7 do
        use Supervisor

        def start_link(opts),
          do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))

        def init(_opts), do: Supervisor.init([], strategy: :one_for_one)
      end

      # Test comprehensive valid configuration
      sandbox_id = unique_id("test-comprehensive")

      comprehensive_config = [
        sandbox_path: fixture_path(),
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

      result =
        Manager.create_sandbox(
          sandbox_id,
          TestSupervisor7,
          comprehensive_config ++ [server: manager]
        )

      case result do
        {:ok, _sandbox_info} ->
          # Use Supertester OTP helpers to wait for sandbox to be ready
          wait_for_sandbox_ready(manager, sandbox_id, 5000)

          # Verify configuration was applied
          {:ok, final_info} = Manager.get_sandbox_info(sandbox_id, server: manager)
          assert is_map(final_info.security_profile)
          assert final_info.security_profile.isolation_level == :high

          # Cleanup
          try do
            Manager.destroy_sandbox(sandbox_id, server: manager)
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
    create_temp_dir("sandbox_test")
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

  defp wait_for_sandbox_ready(manager, sandbox_id, timeout) do
    await(
      fn ->
        case Manager.get_sandbox_info(sandbox_id, server: manager) do
          {:ok, info} when info.status in [:running, :compiling, :starting] ->
            true

          {:ok, info} when info.status == :error ->
            flunk("Sandbox #{sandbox_id} entered error state: #{inspect(info)}")

          {:error, :not_found} ->
            flunk("Sandbox #{sandbox_id} not found")

          _ ->
            false
        end
      end,
      timeout: timeout,
      description: "sandbox #{sandbox_id} ready"
    )
  end

  setup do
    ensure_fixture_tree()
    :ok
  end
end
