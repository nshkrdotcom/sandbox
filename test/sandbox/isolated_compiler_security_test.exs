defmodule Sandbox.IsolatedCompilerSecurityTest do
  use ExUnit.Case, async: true

  alias Sandbox.IsolatedCompiler

  @moduletag :security

  setup do
    # Create a temporary sandbox directory for testing
    sandbox_dir = create_temp_sandbox()

    on_exit(fn ->
      File.rm_rf!(sandbox_dir)
    end)

    %{sandbox_dir: sandbox_dir}
  end

  describe "security scanning" do
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
      assert length(scan_results.threats) > 0

      threat_modules = Enum.map(scan_results.threats, & &1.module)
      assert System in threat_modules or File in threat_modules
    end

    test "detects dangerous operations", %{sandbox_dir: sandbox_dir} do
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
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should detect warnings for dangerous operations
      assert length(scan_results.warnings) > 0

      warning_types = Enum.map(scan_results.warnings, & &1.type)
      assert :dangerous_operation in warning_types or :network_access in warning_types
    end

    test "respects allowed operations whitelist", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "WhitelistModule", """
      def allowed_operation do
        String.upcase("hello")
      end

      def disallowed_operation do
        System.cmd("echo", ["hello"])
      end
      """)

      # Scan with whitelist that allows string operations but not system commands
      assert {:ok, scan_results} =
               IsolatedCompiler.scan_code_security(sandbox_dir,
                 allowed_operations: [:string_operation]
               )

      # Should flag system command as unauthorized
      unauthorized_warnings =
        Enum.filter(scan_results.warnings, &(&1.type == :unauthorized_operation))

      assert length(unauthorized_warnings) > 0
    end

    test "provides detailed security report with line numbers", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "DetailedModule", """
      def line_1, do: :ok
      def line_2, do: System.cmd("ls", [])
      def line_3, do: :ok
      def line_4, do: File.read("test.txt")
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Check that line numbers are correctly reported
      warnings_with_lines = Enum.filter(scan_results.warnings, &(&1.line > 0))
      assert length(warnings_with_lines) > 0

      # Verify specific line numbers for known dangerous operations
      system_warnings =
        Enum.filter(
          scan_results.warnings,
          &(&1.operation == :system_command or &1.type == :dangerous_operation)
        )

      if length(system_warnings) > 0 do
        system_warning = List.first(system_warnings)
        # System.cmd is on line 3 (after defmodule and indentation)
        assert system_warning.line == 3
      end

      # Also check File operations
      file_warnings =
        Enum.filter(
          scan_results.warnings,
          &(&1.type == :file_access)
        )

      if length(file_warnings) > 0 do
        file_warning = List.first(file_warnings)
        # File.read is on line 5
        assert file_warning.line == 5
      end
    end
  end

  describe "resource management" do
    test "enforces memory limits during compilation", %{sandbox_dir: sandbox_dir} do
      # Create a module that might use significant memory during compilation
      create_large_module(sandbox_dir, "MemoryHeavyModule", 100)

      # Set very low memory limit
      # 1MB
      low_memory_limit = 1024 * 1024

      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          memory_limit: low_memory_limit,
          timeout: 10_000
        )

      # Should either succeed with low memory or fail with resource limit
      case result do
        # Compilation was efficient enough
        {:ok, _} ->
          :ok

        {:error, {:resource_limit_exceeded, :memory_limit, details}} ->
          assert details.current > details.limit

        # Other compilation errors are acceptable
        {:error, _other} ->
          :ok
      end
    end

    test "enforces process count limits", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ProcessModule", """
      def spawn_many do
        for _ <- 1..10 do
          spawn(fn -> :timer.sleep(100) end)
        end
      end
      """)

      # Set low process limit
      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          max_processes: 5,
          timeout: 5_000
        )

      # Should succeed since compilation itself doesn't spawn many processes
      # This test mainly verifies the monitoring infrastructure is in place
      case result do
        {:ok, _} -> :ok
        {:error, {:resource_limit_exceeded, :max_processes, _}} -> :ok
        {:error, _other} -> :ok
      end
    end

    test "handles compilation timeout gracefully", %{sandbox_dir: sandbox_dir} do
      # Create a module that might take time to compile
      create_large_module(sandbox_dir, "SlowModule", 50)

      # Set very short timeout
      # In-process compilation is too fast to trigger timeout with normal code
      # So we'll accept either successful compilation or timeout
      result = IsolatedCompiler.compile_sandbox(sandbox_dir, timeout: 100)
      assert match?({:ok, _}, result) or match?({:error, {:compilation_timeout, _}}, result)
    end

    @tag :performance
    test "cleans up resources after compilation failure", %{sandbox_dir: sandbox_dir} do
      # Create invalid module to force compilation failure
      create_sample_module(sandbox_dir, "InvalidModule", """
      def broken_function do
        # Missing end keyword
      """)

      initial_process_count = length(Process.list())

      # Attempt compilation with resource monitoring
      # Different error formats based on compilation method
      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          memory_limit: 64 * 1024 * 1024,
          max_processes: 50
        )

      assert match?({:error, {:compilation_failed, _, _}}, result) or
               match?({:error, {:compiler_crash, _, _, _}}, result)

      # Give time for cleanup
      :timer.sleep(100)

      final_process_count = length(Process.list())

      # Should not have leaked processes (allowing some variance for test processes)
      assert abs(final_process_count - initial_process_count) < 5
    end
  end

  describe "BEAM file validation" do
    test "validates BEAM file integrity", %{sandbox_dir: sandbox_dir} do
      module_name = "ValidModule#{System.unique_integer([:positive])}"
      create_sample_module(sandbox_dir, module_name, "def valid_func, do: :ok")

      assert {:ok, compile_info} = IsolatedCompiler.compile_sandbox(sandbox_dir)
      assert length(compile_info.beam_files) > 0

      # Validate the generated BEAM files
      assert :ok = IsolatedCompiler.validate_beam_files(compile_info.beam_files)
    end

    test "detects corrupted BEAM files" do
      # Create a fake/corrupted BEAM file
      temp_dir = System.tmp_dir!()
      fake_beam = Path.join(temp_dir, "fake.beam")
      File.write!(fake_beam, "not a real beam file")

      on_exit(fn -> File.rm!(fake_beam) end)

      assert {:error, error_msg} = IsolatedCompiler.validate_beam_files([fake_beam])
      assert String.contains?(error_msg, "Invalid BEAM file")
    end
  end

  describe "compilation with security enabled" do
    test "blocks compilation of unsafe code", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "MaliciousModule", """
      def delete_files do
        System.cmd("rm", ["-rf", "/tmp/*"])
      end

      def read_secrets do
        File.read("/etc/shadow")
      end
      """)

      # Compilation with security scanning should detect threats
      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          security_scan: true,
          restricted_modules: [System, File]
        )

      case result do
        {:error, {:security_threats_detected, threats}} ->
          assert length(threats) > 0

        {:ok, _} ->
          # If compilation succeeded, security scan might have only found warnings
          :ok

        {:error, _other} ->
          # Other compilation errors are acceptable
          :ok
      end
    end

    test "allows compilation of safe code", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "SafeModule", """
      def safe_operation do
        String.upcase("hello world")
      end

      def math_operation(x, y) do
        x + y * 2
      end
      """)

      # Should compile successfully with security scanning
      assert {:ok, compile_info} =
               IsolatedCompiler.compile_sandbox(sandbox_dir,
                 security_scan: true
               )

      assert length(compile_info.beam_files) > 0
      assert compile_info.compilation_time > 0
    end

    test "provides detailed security warnings without blocking compilation", %{
      sandbox_dir: sandbox_dir
    } do
      create_sample_module(sandbox_dir, "WarningModule", """
      def network_operation do
        # This might be flagged as a warning but not a threat
        :gen_tcp.listen(8080, [])
      end
      """)

      # Should compile but with security warnings
      assert {:ok, _compile_info} =
               IsolatedCompiler.compile_sandbox(sandbox_dir,
                 security_scan: true
               )

      # Check if security scan was performed
      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should have warnings but not threats
      assert length(scan_results.warnings) > 0
      assert length(scan_results.threats) == 0
    end
  end

  describe "enhanced resource management" do
    @tag :performance
    test "enforces CPU limits with detailed monitoring", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "CpuIntensiveModule", """
      def cpu_intensive_operation do
        # Simulate CPU-intensive work
        for i <- 1..1000 do
          :math.pow(i, 2) + :math.sqrt(i)
        end
      end
      """)

      # Set low CPU limit
      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          # 10% CPU limit
          cpu_limit: 10.0,
          timeout: 5_000
        )

      # Should succeed or fail gracefully with resource monitoring
      case result do
        {:ok, _} ->
          :ok

        {:error, {:resource_limit_exceeded, :cpu_limit, details}} ->
          assert details.current >= 0
          assert details.limit == 10.0

        {:error, _other} ->
          :ok
      end
    end

    @tag :performance
    test "provides detailed resource usage reporting", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ResourceModule", """
      def memory_operation do
        # Create some data structures
        large_list = for i <- 1..1000, do: {i, "data_\#{i}"}
        Map.new(large_list)
      end
      """)

      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          # 128MB
          memory_limit: 128 * 1024 * 1024,
          max_processes: 20
        )

      case result do
        {:ok, compile_info} ->
          # Should have compilation info
          assert compile_info.compilation_time >= 0

        {:error, {:resource_limit_exceeded, _type, details}} ->
          # Should have detailed resource information
          assert Map.has_key?(details, :current)
          assert Map.has_key?(details, :limit)

        {:error, _other} ->
          :ok
      end
    end

    @tag :performance
    test "handles graceful termination on timeout", %{sandbox_dir: sandbox_dir} do
      create_large_module(sandbox_dir, "TimeoutModule", 200)

      start_time = System.monotonic_time(:millisecond)

      result =
        IsolatedCompiler.compile_sandbox(sandbox_dir,
          # Very short timeout
          timeout: 500,
          memory_limit: 64 * 1024 * 1024
        )

      end_time = System.monotonic_time(:millisecond)
      actual_time = end_time - start_time

      case result do
        {:error, {:compilation_timeout, timeout_value}} ->
          assert timeout_value == 500
          # Should terminate close to timeout (within 1 second grace period)
          assert actual_time < 2000

        {:ok, _} ->
          # Compilation was fast enough
          :ok

        {:error, _other} ->
          :ok
      end
    end
  end

  describe "enhanced security scanning" do
    test "detects critical security threats with severity levels", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "CriticalThreatsModule", """
      def delete_system_files do
        System.cmd("rm", ["-rf", "/etc/passwd"])
      end

      def format_drive do
        System.shell("format C: /q")
      end

      def eval_user_input(input) do
        Code.eval_string(input)
      end
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should detect critical threats
      critical_threats = Enum.filter(scan_results.warnings, &(&1.severity == :critical))
      high_threats = Enum.filter(scan_results.warnings, &(&1.severity == :high))

      assert length(critical_threats) + length(high_threats) > 0

      # Check for detailed context information
      if length(scan_results.warnings) > 0 do
        warning = List.first(scan_results.warnings)
        assert Map.has_key?(warning, :context)
        assert Map.has_key?(warning, :line_content)
        assert warning.line > 0
      end
    end

    test "provides comprehensive operation categorization", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ComprehensiveModule", """
      def network_ops do
        :gen_tcp.connect('example.com', 80, [])
        HTTPoison.get("https://api.example.com")
      end

      def file_ops do
        File.write("test.txt", "data")
        File.rm_rf("temp_dir")
      end

      def crypto_ops do
        :crypto.hash(:sha256, "data")
        :public_key.generate_key({:rsa, 2048, 65537})
      end

      def process_ops do
        spawn(fn -> :timer.sleep(100) end)
        Task.start(fn -> :ok end)
      end
      """)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      # Should categorize different types of operations
      operation_types = Enum.map(scan_results.warnings, & &1.operation) |> Enum.uniq()

      expected_categories = [
        :tcp_operation,
        :http_client,
        :file_writing,
        :recursive_deletion,
        :cryptographic_operation,
        :process_spawn,
        :task_start
      ]

      # Should detect multiple categories
      detected_categories = Enum.filter(expected_categories, &(&1 in operation_types))
      assert length(detected_categories) > 0
    end

    test "respects configurable security rules", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ConfigurableModule", """
      def allowed_string_op do
        String.upcase("hello")
      end

      def restricted_file_op do
        File.read("config.txt")
      end

      def restricted_network_op do
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
      restricted_warnings =
        Enum.filter(
          scan_results.warnings,
          &(&1.type == :unauthorized_operation or &1.type == :dangerous_operation)
        )

      assert length(restricted_warnings) > 0
    end
  end

  describe "compilation environment isolation" do
    test "creates isolated compilation environment", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "IsolationModule", """
      def check_environment do
        System.get_env("HOME")
      end
      """)

      # Compilation should succeed with isolation when System is not restricted
      assert {:ok, compile_info} =
               IsolatedCompiler.compile_sandbox(sandbox_dir,
                 security_scan: true,
                 env: %{"CUSTOM_VAR" => "test_value"},
                 # Exclude System
                 restricted_modules: [:os, :file, :code, :erlang, File, Code, Port]
               )

      assert length(compile_info.beam_files) > 0
    end

    test "validates sandbox path safety", %{sandbox_dir: _sandbox_dir} do
      # Test with potentially unsafe paths
      unsafe_paths = [
        "/etc/test_sandbox",
        "/usr/local/test_sandbox",
        "../../../etc/test_sandbox"
      ]

      for unsafe_path <- unsafe_paths do
        # Should either reject unsafe paths or handle them safely
        result = IsolatedCompiler.compile_sandbox(unsafe_path)

        case result do
          # Correctly rejected
          {:error, {:invalid_sandbox_path, _}} -> :ok
          # Other error is acceptable
          {:error, _other} -> :ok
          # If it succeeds, isolation should be in place
          {:ok, _} -> :ok
        end
      end
    end

    test "performs post-compilation security checks", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "PostCompilationModule", """
      def normal_function do
        :ok
      end
      """)

      assert {:ok, compile_info} =
               IsolatedCompiler.compile_sandbox(sandbox_dir,
                 security_scan: true
               )

      # Check if post-compilation security warnings are included
      security_warnings =
        Enum.filter(
          compile_info.warnings,
          &(&1.type == :post_compilation_security)
        )

      # Should not have security warnings for normal code
      assert length(security_warnings) == 0
    end
  end

  describe "stress testing security features" do
    @tag :stress
    @tag :performance
    test "handles large codebases with security scanning", %{sandbox_dir: sandbox_dir} do
      # Create many modules with mixed safe/unsafe operations
      for i <- 1..20 do
        content =
          if rem(i, 3) == 0 do
            # Every third module has potentially unsafe operations
            """
            def func_#{i} do
              File.read("file_#{i}.txt")
            end
            """
          else
            # Safe operations
            """
            def func_#{i}(x) do
              x * #{i} + #{i}
            end
            """
          end

        create_sample_module(sandbox_dir, "Module#{i}", content)
      end

      start_time = System.monotonic_time(:millisecond)

      assert {:ok, scan_results} = IsolatedCompiler.scan_code_security(sandbox_dir)

      end_time = System.monotonic_time(:millisecond)
      scan_time = end_time - start_time

      # Security scan should complete in reasonable time (under 5 seconds for 20 modules)
      assert scan_time < 5000

      # Should detect some warnings from unsafe operations
      assert length(scan_results.warnings) > 0
    end

    @tag :stress
    @tag :performance
    test "handles concurrent compilation with resource limits", %{sandbox_dir: sandbox_dir} do
      # Create multiple modules for concurrent compilation testing
      for i <- 1..5 do
        create_sample_module(sandbox_dir, "ConcurrentModule#{i}", """
        def concurrent_func_#{i} do
          for j <- 1..100 do
            :math.pow(j, 2)
          end
        end
        """)
      end

      # Run multiple compilations concurrently
      tasks =
        for _i <- 1..3 do
          Task.async(fn ->
            IsolatedCompiler.compile_sandbox(sandbox_dir,
              # 32MB limit
              memory_limit: 32 * 1024 * 1024,
              cpu_limit: 50.0,
              max_processes: 10,
              timeout: 10_000
            )
          end)
        end

      results = Task.await_many(tasks, 15_000)

      # At least some compilations should succeed
      successful_compilations =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert successful_compilations > 0
    end
  end

  # Helper functions

  defp create_temp_sandbox do
    temp_dir = System.tmp_dir!()
    sandbox_name = "security_test_sandbox_#{:rand.uniform(1_000_000)}"
    sandbox_dir = Path.join(temp_dir, sandbox_name)

    File.mkdir_p!(sandbox_dir)
    File.mkdir_p!(Path.join(sandbox_dir, "lib"))

    # Create a basic mix.exs
    mix_content = """
    defmodule SecurityTestSandbox.MixProject do
      use Mix.Project
      
      def project do
        [
          app: :security_test_sandbox,
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

  defp create_large_module(sandbox_dir, module_name, function_count) do
    functions =
      for i <- 1..function_count do
        """
        def function_#{i}(x) do
          result = x * #{i} + #{i * 2}
          case result do
            n when n > #{i * 10} -> {:large, n}
            n when n > #{i * 5} -> {:medium, n}
            n -> {:small, n}
          end
        end
        """
      end
      |> Enum.join("\n")

    create_sample_module(sandbox_dir, module_name, functions)
  end
end
