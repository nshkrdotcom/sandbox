defmodule SandboxIntegrationTest do
  use Sandbox.SerialCase

  describe "basic sandbox structure" do
    test "application starts with all components" do
      # Verify the application is running
      assert Process.whereis(Sandbox.Manager) != nil
      assert Process.whereis(Sandbox.ModuleVersionManager) != nil
      assert Process.whereis(Sandbox.ResourceMonitor) != nil
      assert Process.whereis(Sandbox.SecurityController) != nil
      assert Process.whereis(Sandbox.FileWatcher) != nil
      assert Process.whereis(Sandbox.StatePreservation) != nil
    end

    test "ETS tables can be initialized and have correct properties" do
      # Ensure tables are initialized
      :ok = Sandbox.Application.init_ets_tables()

      # Verify all required ETS tables exist
      assert :ets.whereis(:sandbox_registry) != :undefined
      assert :ets.whereis(:sandbox_modules) != :undefined
      assert :ets.whereis(:sandbox_resources) != :undefined
      assert :ets.whereis(:sandbox_security) != :undefined

      # Verify table properties
      registry_info = :ets.info(:sandbox_registry)
      assert registry_info[:type] == :set
      assert registry_info[:protection] == :public

      modules_info = :ets.info(:sandbox_modules)
      assert modules_info[:type] == :bag
      assert modules_info[:protection] == :public
    end

    test "sandbox manager responds to basic calls" do
      # Test that the manager is responsive
      sandboxes = Sandbox.list_sandboxes()
      assert is_list(sandboxes)

      # Test getting info for non-existent sandbox
      assert {:error, :not_found} = Sandbox.get_sandbox_info("non-existent")
    end

    test "data models work correctly" do
      # Test SandboxState creation
      state = Sandbox.Models.SandboxState.new("test-sandbox", TestSupervisor)
      assert state.id == "test-sandbox"
      assert state.supervisor_module == TestSupervisor
      assert state.status == :initializing

      # Test state update
      updated_state = Sandbox.Models.SandboxState.update(state, status: :running)
      assert updated_state.status == :running

      # Test conversion to info
      info = Sandbox.Models.SandboxState.to_info(updated_state)
      assert info.id == "test-sandbox"
      assert info.status == :running
    end

    test "module version model works correctly" do
      # Dummy BEAM data
      beam_data = <<1, 2, 3, 4>>

      version = Sandbox.Models.ModuleVersion.new("test-sandbox", TestModule, beam_data)
      assert version.sandbox_id == "test-sandbox"
      assert version.module == TestModule
      assert version.version == 1
      assert version.beam_data == beam_data
      assert is_binary(version.beam_checksum)

      # Test conversion to info
      info = Sandbox.Models.ModuleVersion.to_info(version)
      assert info.sandbox_id == "test-sandbox"
      assert info.module == TestModule
      assert info.version == 1
    end

    test "compilation result model works correctly" do
      # Test successful compilation
      success_result =
        Sandbox.Models.CompilationResult.success(
          beam_files: ["test.beam"],
          compilation_time: 1000
        )

      assert Sandbox.Models.CompilationResult.success?(success_result)
      assert success_result.beam_files == ["test.beam"]
      assert success_result.compilation_time == 1000

      # Test failed compilation
      errors = [Sandbox.Models.CompilationResult.error("test.ex", 10, "syntax error")]
      failure_result = Sandbox.Models.CompilationResult.failure(errors)

      assert not Sandbox.Models.CompilationResult.success?(failure_result)
      assert length(failure_result.errors) == 1
      assert Sandbox.Models.CompilationResult.issue_count(failure_result) == 1
    end
  end

  describe "telemetry integration" do
    test "application startup emits telemetry events" do
      # This test verifies that telemetry is properly integrated
      # The actual telemetry event was emitted during application startup
      # We can verify the telemetry module is available
      assert Code.ensure_loaded?(:telemetry)
    end
  end
end
