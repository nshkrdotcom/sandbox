defmodule Sandbox.Models.SandboxStateTest do
  use Sandbox.TestCase

  alias Sandbox.Models.SandboxState

  describe "new/3" do
    test "creates a new sandbox state with defaults" do
      state = SandboxState.new("test-sandbox", TestSupervisor)

      assert state.id == "test-sandbox"
      assert state.supervisor_module == TestSupervisor
      assert state.app_name == :sandbox_test_sandbox
      assert state.status == :initializing
      assert state.restart_count == 0
      assert state.auto_reload_enabled == false
      assert is_struct(state.created_at, DateTime)
      assert is_struct(state.updated_at, DateTime)
    end

    test "creates sandbox state with custom options" do
      opts = [
        auto_reload: true,
        sandbox_path: "/tmp/test",
        compile_timeout: 60_000,
        security_profile: :high,
        resource_limits: %{max_memory: 64 * 1024 * 1024}
      ]

      state = SandboxState.new("test-sandbox", TestSupervisor, opts)

      assert state.auto_reload_enabled == true
      assert state.config.sandbox_path == "/tmp/test"
      assert state.config.compile_timeout == 60_000
      assert state.security_profile.isolation_level == :high
      assert state.config.resource_limits.max_memory == 64 * 1024 * 1024
    end
  end

  describe "update/2" do
    test "updates sandbox state and timestamp" do
      state = SandboxState.new("test-sandbox", TestSupervisor)
      original_time = state.updated_at

      updated_state = SandboxState.update(state, status: :running, app_pid: self())

      assert updated_state.status == :running
      assert updated_state.app_pid == self()
      assert DateTime.compare(updated_state.updated_at, original_time) in [:eq, :gt]
    end
  end

  describe "to_info/1" do
    test "converts state to info map" do
      state =
        SandboxState.new("test-sandbox", TestSupervisor)
        |> SandboxState.update(status: :running, app_pid: self())

      info = SandboxState.to_info(state)

      assert info.id == "test-sandbox"
      assert info.status == :running
      assert info.app_pid == self()
      assert info.supervisor_module == TestSupervisor
      assert is_struct(info.created_at, DateTime)
      assert is_integer(info.restart_count)
    end
  end

  describe "security profiles" do
    test "high security profile has strict limits" do
      state = SandboxState.new("test", TestSupervisor, security_profile: :high)

      profile = state.security_profile
      assert profile.isolation_level == :high
      assert profile.audit_level == :full
      assert :file in profile.restricted_modules
      assert :basic_otp in profile.allowed_operations
    end

    test "low security profile is permissive" do
      state = SandboxState.new("test", TestSupervisor, security_profile: :low)

      profile = state.security_profile
      assert profile.isolation_level == :low
      assert profile.allowed_operations == [:all]
      assert profile.restricted_modules == []
    end

    test "custom security profile" do
      custom_profile = %{
        isolation_level: :custom,
        allowed_operations: [:test_ops],
        restricted_modules: [:test_module],
        audit_level: :custom
      }

      state = SandboxState.new("test", TestSupervisor, security_profile: custom_profile)

      assert state.security_profile == custom_profile
    end
  end

  describe "resource limits" do
    test "default resource limits are reasonable" do
      state = SandboxState.new("test", TestSupervisor)

      limits = state.config.resource_limits
      # 128MB
      assert limits.max_memory == 128 * 1024 * 1024
      assert limits.max_processes == 100
      # 5 minutes
      assert limits.max_execution_time == 300_000
      assert limits.max_cpu_percentage == 50.0
    end

    test "custom resource limits are applied" do
      custom_limits = %{
        max_memory: 256 * 1024 * 1024,
        max_processes: 200,
        max_execution_time: 600_000,
        max_cpu_percentage: 75.0
      }

      state = SandboxState.new("test", TestSupervisor, resource_limits: custom_limits)

      limits = state.config.resource_limits
      assert limits.max_memory == 256 * 1024 * 1024
      assert limits.max_processes == 200
      assert limits.max_execution_time == 600_000
      assert limits.max_cpu_percentage == 75.0
    end
  end
end
