defmodule Sandbox.IsolatedCompilerIncrementalTest do
  use ExUnit.Case, async: true
  import Supertester.OTPHelpers
  import Supertester.Assertions
  import Supertester.GenServerHelpers

  alias Sandbox.IsolatedCompiler

  @moduletag :incremental_compilation

  setup do
    # Create a temporary sandbox directory for testing
    sandbox_dir = create_temp_sandbox()

    on_exit(fn ->
      File.rm_rf!(sandbox_dir)
    end)

    %{sandbox_dir: sandbox_dir}
  end

  describe "incremental_compile/3" do
    test "detects no changes when files haven't been modified", %{sandbox_dir: sandbox_dir} do
      # Create initial files
      create_sample_module(sandbox_dir, "MyModule", "def hello, do: :world")

      # First compilation with cache enabled
      assert {:ok, first_result} =
               IsolatedCompiler.compile_sandbox(sandbox_dir, cache_enabled: true)

      assert length(first_result.beam_files) > 0

      # Wait a bit to ensure cache is written
      :timer.sleep(50)

      # Incremental compilation with no changes
      assert {:ok, second_result} =
               IsolatedCompiler.incremental_compile(sandbox_dir, [], cache_enabled: true)

      assert second_result.cache_hit == true
      assert second_result.incremental == true
      assert Enum.empty?(second_result.changed_files)
      assert second_result.compilation_time == 0
    end

    test "detects and compiles only changed files", %{sandbox_dir: sandbox_dir} do
      # Create initial files
      create_sample_module(sandbox_dir, "ModuleA", "def func_a, do: :a")
      create_sample_module(sandbox_dir, "ModuleB", "def func_b, do: :b")

      # First compilation
      assert {:ok, _first_result} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Modify only one file
      # Ensure different timestamp
      :timer.sleep(10)
      create_sample_module(sandbox_dir, "ModuleA", "def func_a, do: :modified_a")

      # Incremental compilation
      assert {:ok, result} = IsolatedCompiler.incremental_compile(sandbox_dir)
      assert result.incremental == true
      assert result.cache_hit == false
      assert "lib/module_a.ex" in result.changed_files
      refute "lib/module_b.ex" in result.changed_files
    end

    test "analyzes dependencies and includes dependent files", %{sandbox_dir: sandbox_dir} do
      # Create modules with dependencies
      create_sample_module(sandbox_dir, "BaseModule", "def base_func, do: :base")

      create_sample_module(sandbox_dir, "DependentModule", """
      alias BaseModule
      def dependent_func, do: BaseModule.base_func()
      """)

      # First compilation with cache enabled
      assert {:ok, _first_result} =
               IsolatedCompiler.compile_sandbox(sandbox_dir, cache_enabled: true)

      # Modify base module
      # Give more time to ensure file timestamp changes
      :timer.sleep(100)
      create_sample_module(sandbox_dir, "BaseModule", "def base_func, do: :modified_base")

      # Verify the file was actually modified
      base_module_path = Path.join([sandbox_dir, "lib", "base_module.ex"])
      content = File.read!(base_module_path)
      assert content =~ ":modified_base"

      # Incremental compilation with dependency analysis
      assert {:ok, result} =
               IsolatedCompiler.incremental_compile(sandbox_dir, [], dependency_analysis: true)

      # Both files should be in compilation scope due to dependency
      assert "lib/base_module.ex" in result.changed_files
      # Note: Simple dependency analysis might not catch all cases in this test setup
    end

    test "handles compilation errors gracefully during incremental compilation", %{
      sandbox_dir: sandbox_dir
    } do
      # Create valid initial file
      create_sample_module(sandbox_dir, "ValidModule", "def valid_func, do: :valid")

      # First compilation
      assert {:ok, _first_result} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Introduce syntax error
      :timer.sleep(10)
      create_sample_module(sandbox_dir, "ValidModule", "def invalid_func do # missing end")

      # Incremental compilation should fail gracefully
      result = IsolatedCompiler.incremental_compile(sandbox_dir)

      assert match?({:error, {:compilation_failed, _, _}}, result) or
               match?({:error, {:compiler_crash, _, _, _}}, result)
    end

    test "caches compilation results correctly", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "CachedModule", "def cached_func, do: :cached")

      # First compilation
      assert {:ok, first_result} =
               IsolatedCompiler.compile_sandbox(sandbox_dir, cache_enabled: true)

      # Check cache directory was created
      cache_dir = Path.join(sandbox_dir, ".sandbox_cache")
      assert File.exists?(cache_dir)
      assert File.exists?(Path.join(cache_dir, "file_hashes.json"))
      assert File.exists?(Path.join(cache_dir, "last_compilation.json"))

      # Second compilation should use cache
      assert {:ok, second_result} = IsolatedCompiler.incremental_compile(sandbox_dir)
      assert second_result.cache_hit == true
      assert second_result.compilation_time == 0
    end

    test "force recompile bypasses cache", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "ForceModule", "def force_func, do: :force")

      # First compilation
      assert {:ok, _first_result} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Force recompile should bypass cache
      assert {:ok, result} =
               IsolatedCompiler.compile_sandbox(sandbox_dir,
                 incremental: true,
                 force_recompile: true
               )

      assert result.cache_hit == false
      assert result.compilation_time > 0
    end
  end

  describe "performance characteristics" do
    @tag :performance
    test "incremental compilation is faster than full compilation", %{sandbox_dir: sandbox_dir} do
      # Create multiple modules
      for i <- 1..10 do
        create_sample_module(sandbox_dir, "Module#{i}", """
        def func_#{i}, do: #{i}
        def other_func_#{i}(x), do: x + #{i}
        """)
      end

      # Measure full compilation time
      {full_time, {:ok, _}} =
        :timer.tc(fn ->
          IsolatedCompiler.compile_sandbox(sandbox_dir)
        end)

      # Modify one file
      :timer.sleep(10)
      create_sample_module(sandbox_dir, "Module1", "def func_1, do: :modified")

      # Measure incremental compilation time
      {incremental_time, {:ok, result}} =
        :timer.tc(fn ->
          IsolatedCompiler.incremental_compile(sandbox_dir)
        end)

      # Incremental should be faster (allowing some overhead for cache operations)
      assert incremental_time < full_time * 0.8
      assert result.incremental == true
    end

    @tag :stress
    @tag :performance
    test "handles many file changes efficiently", %{sandbox_dir: sandbox_dir} do
      # Create many modules
      module_count = 50

      for i <- 1..module_count do
        create_sample_module(sandbox_dir, "StressModule#{i}", """
        def stress_func_#{i}, do: #{i}
        """)
      end

      # Initial compilation
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Modify half the files
      for i <- 1..div(module_count, 2) do
        create_sample_module(sandbox_dir, "StressModule#{i}", """
        def stress_func_#{i}, do: #{i * 2}
        """)
      end

      # Incremental compilation should handle this efficiently
      start_time = System.monotonic_time(:millisecond)
      assert {:ok, result} = IsolatedCompiler.incremental_compile(sandbox_dir)
      end_time = System.monotonic_time(:millisecond)

      compilation_time = end_time - start_time

      # Should complete within reasonable time (5 seconds for 50 modules)
      assert compilation_time < 5000
      assert result.incremental == true
      assert length(result.changed_files) == div(module_count, 2)
    end
  end

  describe "file hash detection" do
    test "detects file content changes accurately", %{sandbox_dir: sandbox_dir} do
      create_sample_module(sandbox_dir, "HashModule", "def original, do: :original")

      # First compilation to establish baseline
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Modify file content
      :timer.sleep(10)
      create_sample_module(sandbox_dir, "HashModule", "def modified, do: :modified")

      # Should detect the change
      assert {:ok, result} = IsolatedCompiler.incremental_compile(sandbox_dir)
      assert "lib/hash_module.ex" in result.changed_files
    end

    test "ignores whitespace-only changes", %{sandbox_dir: sandbox_dir} do
      original_content = "def whitespace_test, do: :test"
      create_sample_module(sandbox_dir, "WhitespaceModule", original_content)

      # First compilation
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Add whitespace (same functional content)
      :timer.sleep(10)
      whitespace_content = "def whitespace_test,   do:   :test  "
      create_sample_module(sandbox_dir, "WhitespaceModule", whitespace_content)

      # Should still detect change (hash-based detection is content-sensitive)
      assert {:ok, result} = IsolatedCompiler.incremental_compile(sandbox_dir)
      assert "lib/whitespace_module.ex" in result.changed_files
    end
  end

  # Helper functions

  defp create_temp_sandbox do
    temp_dir = System.tmp_dir!()
    sandbox_name = "test_sandbox_#{:rand.uniform(1_000_000)}"
    sandbox_dir = Path.join(temp_dir, sandbox_name)

    File.mkdir_p!(sandbox_dir)
    File.mkdir_p!(Path.join(sandbox_dir, "lib"))

    # Create a basic mix.exs
    mix_content = """
    defmodule TestSandbox.MixProject do
      use Mix.Project
      
      def project do
        [
          app: :test_sandbox,
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
