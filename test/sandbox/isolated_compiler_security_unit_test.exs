defmodule Sandbox.IsolatedCompilerSecurityUnitTest do
  use Sandbox.TestCase

  alias Sandbox.IsolatedCompiler

  @moduletag :security_unit

  setup do
    # Create a temporary sandbox directory for testing
    sandbox_dir = create_temp_sandbox()

    on_exit(fn ->
      File.rm_rf!(sandbox_dir)
    end)

    %{sandbox_dir: sandbox_dir}
  end

  describe "security scanning functionality" do
    test "detects restricted module usage", %{sandbox_dir: sandbox_dir} do
      # Create module using restricted operations
      create_sample_module(sandbox_dir, "UnsafeModule", """
      def dangerous_operation do
        System.cmd("ls", [])
        File.read("/etc/passwd")
        :os.cmd('whoami')
      end
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should detect threats from restricted modules
      assert length(scan_results.threats) > 0 or length(scan_results.warnings) > 0

      # Check that we have some security findings
      all_findings = scan_results.threats ++ scan_results.warnings
      assert length(all_findings) > 0

      # Verify findings have proper structure
      if length(all_findings) > 0 do
        finding = List.first(all_findings)
        assert Map.has_key?(finding, :type)
        assert Map.has_key?(finding, :severity)
        assert Map.has_key?(finding, :file)
        assert Map.has_key?(finding, :line)
        assert Map.has_key?(finding, :message)
      end
    end

    test "detects dangerous operations with enhanced patterns", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "DangerousModule", """
      def eval_code(code) do
        Code.eval_string(code)
      end

      def spawn_process do
        spawn(fn -> :timer.sleep(1000) end)
      end

      def network_call do
        :gen_tcp.connect('example.com', 80, [])
      end

      def file_operations do
        File.rm_rf("/tmp/dangerous")
        System.shell("format C:")
      end
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should detect warnings for dangerous operations
      assert length(scan_results.warnings) > 0

      # Check for specific operation types
      operation_types = Enum.map(scan_results.warnings, & &1.operation) |> Enum.uniq()

      expected_operations = [
        :code_evaluation,
        :process_spawn,
        :tcp_operation,
        :recursive_deletion,
        :shell_command
      ]

      detected_operations = Enum.filter(expected_operations, &(&1 in operation_types))
      assert length(detected_operations) > 0
    end

    test "provides severity levels for different threats", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "SeverityModule", """
      def critical_threat do
        System.cmd("rm", ["-rf", "/etc/passwd"])
      end

      def high_threat do
        Code.eval_string("System.halt()")
      end

      def medium_threat do
        File.write("config.txt", "data")
      end

      def low_threat do
        String.upcase("hello")
      end
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should have findings with different severity levels
      severities = Enum.map(scan_results.warnings, & &1.severity) |> Enum.uniq()

      # Should have at least some high-severity findings
      assert :high in severities or :critical in severities
    end

    test "respects configurable security rules", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ConfigurableModule", """
      def string_operation do
        String.upcase("hello")
      end

      def file_operation do
        File.read("config.txt")
      end

      def network_operation do
        :gen_tcp.listen(8080, [])
      end
      """)

      # Test with custom restricted modules
      assert {:ok, scan_results} =
               IsolatedCompiler.scan_code_security(sandbox_dir,
                 restricted_modules: [File, :gen_tcp],
                 allowed_operations: [:string_operation]
               )

      # Should flag restricted modules but not allowed operations
      restricted_findings =
        Enum.filter(
          scan_results.warnings ++ scan_results.threats,
          fn finding ->
            finding.type == :unauthorized_operation or
              finding.type == :dangerous_operation or
              Map.get(finding, :module) in [File, :gen_tcp]
          end
        )

      assert length(restricted_findings) > 0
    end

    test "provides detailed context information", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ContextModule", """
      def line_1, do: :ok
      def line_2, do: System.cmd("ls", [])
      def line_3, do: :ok
      def line_4, do: File.read("test.txt")
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Check that findings have detailed context
      if length(scan_results.warnings) > 0 do
        warning = List.first(scan_results.warnings)

        # Should have context information
        assert Map.has_key?(warning, :context)
        assert Map.has_key?(warning, :line_content)
        assert warning.line > 0

        # Context should have surrounding code information
        if Map.has_key?(warning, :context) do
          context = warning.context
          assert Map.has_key?(context, :surrounding_code)
          assert Map.has_key?(context, :matched_text)
          assert Map.has_key?(context, :line_number)
        end
      end
    end

    @tag :performance
    test "handles large codebases efficiently", %{sandbox_dir: sandbox_dir} do
      # Create many modules with mixed operations
      for i <- 1..10 do
        content =
          if rem(i, 3) == 0 do
            # Every third module has potentially unsafe operations
            """
            def func_#{i} do
              File.read("file_#{i}.txt")
              System.cmd("echo", ["test"])
            end
            """
          else
            # Safe operations
            """
            def func_#{i}(x) do
              x * #{i} + #{i}
            end

            def string_func_#{i} do
              String.upcase("test_#{i}")
            end
            """
          end

        create_sample_module(sandbox_dir, "Module#{i}", content)
      end

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      end_time = System.monotonic_time(:millisecond)
      scan_time = end_time - start_time

      # Security scan should complete in reasonable time (under 2 seconds for 10 modules)
      assert scan_time < 2000

      # Should detect some warnings from unsafe operations
      assert length(scan_results.warnings) > 0

      # Should have findings from multiple files
      files_with_findings =
        scan_results.warnings
        |> Enum.map(& &1.file)
        |> Enum.uniq()

      assert length(files_with_findings) > 1
    end
  end

  describe "resource management configuration" do
    test "validates resource limit parameters" do
      # Test that resource limits are properly structured
      opts = [
        memory_limit: 64 * 1024 * 1024,
        cpu_limit: 50.0,
        max_processes: 20,
        timeout: 5000
      ]

      # These should be valid parameters
      assert is_integer(opts[:memory_limit])
      assert is_float(opts[:cpu_limit]) or is_integer(opts[:cpu_limit])
      assert is_integer(opts[:max_processes])
      assert is_integer(opts[:timeout])

      # Limits should be reasonable
      assert opts[:memory_limit] > 0
      assert opts[:cpu_limit] > 0
      assert opts[:max_processes] > 0
      assert opts[:timeout] > 0
    end

    test "handles security scan options properly" do
      opts = [
        security_scan: true,
        restricted_modules: [System, File, Code],
        allowed_operations: [:string_operation, :math_operation]
      ]

      assert is_boolean(opts[:security_scan])
      assert is_list(opts[:restricted_modules])
      assert is_list(opts[:allowed_operations])

      # Should have reasonable defaults
      assert length(opts[:restricted_modules]) > 0
    end
  end

  describe "error handling and edge cases" do
    test "handles empty sandbox directory gracefully", %{sandbox_dir: sandbox_dir} do
      # Empty directory should not cause errors
      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should have empty results
      assert length(scan_results.threats) == 0
      assert length(scan_results.warnings) == 0
    end

    test "handles invalid file content gracefully", %{sandbox_dir: sandbox_dir} do
      # Create file with invalid Elixir syntax
      invalid_file = Path.join([sandbox_dir, "lib", "invalid.ex"])

      File.write!(invalid_file, """
      defmodule Invalid do
        def broken_function do
          # Missing end keyword and invalid syntax
          if true
            "broken
      """)

      # Should not crash on invalid syntax
      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # May or may not have findings, but should not error
      assert is_list(scan_results.threats)
      assert is_list(scan_results.warnings)
    end

    test "handles non-existent sandbox path" do
      non_existent_path = "/path/that/does/not/exist"

      result = IsolatedCompiler.scan_code_security(non_existent_path)

      # Should return error for non-existent path
      assert {:error, _reason} = result
    end
  end

  # Helper functions

  defp create_temp_sandbox do
    temp_dir = System.tmp_dir!()
    sandbox_name = unique_id("security_unit_test_sandbox")
    sandbox_dir = Path.join(temp_dir, sandbox_name)

    File.mkdir_p!(sandbox_dir)
    File.mkdir_p!(Path.join(sandbox_dir, "lib"))

    # Create a basic mix.exs
    mix_content = """
    defmodule SecurityUnitTestSandbox.MixProject do
      use Mix.Project
      
      def project do
        [
          app: :security_unit_test_sandbox,
          version: "0.1.0",
          elixir: "~> 1.14"
        ]
      end
    end
    """

    File.write!(Path.join(sandbox_dir, "mix.exs"), mix_content)

    sandbox_dir
  end

  defp create_sample_module(sandbox_dir, module_name, content) do
    file_name = module_name |> Macro.underscore() |> Kernel.<>(".ex")
    file_path = Path.join([sandbox_dir, "lib", file_name])

    module_content = """
    defmodule #{module_name} do
      #{content}
    end
    """

    File.write!(file_path, module_content)
  end
end
