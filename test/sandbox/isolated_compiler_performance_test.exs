defmodule Sandbox.IsolatedCompilerPerformanceTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Sandbox.TestHelpers
  import Supertester.Assertions

  alias Sandbox.IsolatedCompiler

  @moduletag :performance
  @moduletag :incremental_compilation

  setup do
    # Create a temporary sandbox directory for testing
    sandbox_dir = create_temp_sandbox()

    on_exit(fn ->
      File.rm_rf!(sandbox_dir)
    end)

    %{sandbox_dir: sandbox_dir}
  end

  describe "incremental compilation performance" do
    @tag :stress
    test "incremental compilation is significantly faster than full compilation", %{
      sandbox_dir: sandbox_dir
    } do
      # Create a moderately complex project
      module_count = 20
      create_complex_project(sandbox_dir, module_count)

      # Measure full compilation time
      {full_time, {:ok, _full_result}} =
        :timer.tc(fn ->
          IsolatedCompiler.compile_sandbox(sandbox_dir, cache_enabled: true)
        end)

      # Modify a single file (helper bumps mtime for change detection)
      modify_single_module(sandbox_dir, "Module1", "def modified_func, do: :modified")

      # Measure incremental compilation time
      {incremental_time, {:ok, incremental_result}} =
        :timer.tc(fn ->
          IsolatedCompiler.incremental_compile(sandbox_dir, [], dependency_analysis: true)
        end)

      # Performance assertions
      assert incremental_result.incremental == true
      assert incremental_result.cache_hit == false
      # Should be minimal
      assert length(incremental_result.changed_files) <= 3

      # Incremental should be at least 3x faster
      speedup_ratio = full_time / incremental_time

      assert speedup_ratio >= 3.0,
             "Expected speedup of at least 3x, got #{Float.round(speedup_ratio, 2)}x"

      # Incremental should complete in under 2 seconds
      assert incremental_time < 2_000_000,
             "Incremental compilation took #{incremental_time / 1000}ms, expected < 2000ms"
    end

    @tag :stress
    test "cache hit performance is extremely fast", %{sandbox_dir: sandbox_dir} do
      create_simple_project(sandbox_dir, 5)

      # Initial compilation to populate cache
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir, cache_enabled: true)

      # Measure cache hit performance
      {cache_hit_time, {:ok, cache_result}} =
        :timer.tc(fn ->
          IsolatedCompiler.incremental_compile(sandbox_dir)
        end)

      # Cache hit assertions
      assert cache_result.cache_hit == true
      assert cache_result.compilation_time == 0
      assert Enum.empty?(cache_result.changed_files)

      # Cache hit should be extremely fast (under 100ms)
      assert cache_hit_time < 100_000,
             "Cache hit took #{cache_hit_time / 1000}ms, expected < 100ms"
    end

    @tag :stress
    test "function-level change detection performance", %{sandbox_dir: sandbox_dir} do
      create_function_heavy_project(sandbox_dir)

      # Initial compilation
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Modify only function bodies (not signatures)
      modify_function_bodies(sandbox_dir)

      # Measure function-level incremental compilation
      {function_time, {:ok, function_result}} =
        :timer.tc(fn ->
          IsolatedCompiler.incremental_compile(sandbox_dir, [], dependency_analysis: true)
        end)

      # Should detect function-level changes
      assert function_result.incremental == true
      assert Map.get(function_result, :compilation_strategy) in [:incremental, :full]

      # Should be reasonably fast
      assert function_time < 3_000_000,
             "Function-level compilation took #{function_time / 1000}ms, expected < 3000ms"
    end

    @tag :stress
    test "dependency analysis performance with complex dependencies", %{sandbox_dir: sandbox_dir} do
      create_dependency_heavy_project(sandbox_dir)

      # Initial compilation
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Modify a base module that many others depend on
      modify_base_module(sandbox_dir)

      # Measure dependency analysis performance
      {dep_time, {:ok, dep_result}} =
        :timer.tc(fn ->
          IsolatedCompiler.incremental_compile(sandbox_dir, [], dependency_analysis: true)
        end)

      # Should include dependent modules
      assert length(dep_result.changed_files) > 1
      assert dep_result.incremental == true

      # Dependency analysis should complete in reasonable time
      assert dep_time < 5_000_000,
             "Dependency analysis took #{dep_time / 1000}ms, expected < 5000ms"
    end
  end

  describe "compilation caching performance" do
    @tag :stress
    test "cache statistics tracking performance", %{sandbox_dir: sandbox_dir} do
      create_simple_project(sandbox_dir, 3)

      # Perform multiple compilations to build statistics
      compilation_times =
        for i <- 1..10 do
          if rem(i, 3) == 0 do
            # Modify file every 3rd iteration
            modify_single_module(sandbox_dir, "Module1", "def func_#{i}, do: #{i}")
          end

          {time, {:ok, _result}} =
            :timer.tc(fn ->
              if i == 1 do
                IsolatedCompiler.compile_sandbox(sandbox_dir, cache_enabled: true)
              else
                IsolatedCompiler.incremental_compile(sandbox_dir)
              end
            end)

          time
        end

      # Get cache statistics
      {stats_time, {:ok, stats}} =
        :timer.tc(fn ->
          IsolatedCompiler.get_cache_statistics(sandbox_dir)
        end)

      # Statistics should be available quickly
      assert stats_time < 50_000, "Cache statistics took #{stats_time / 1000}ms, expected < 50ms"

      # Verify statistics accuracy
      assert stats.total_compilations == 10
      assert stats.cache_hits > 0
      assert stats.incremental_compilations > 0
      assert stats.cache_hit_rate > 0.0
      assert stats.average_compilation_time > 0

      # Performance should improve over time (more cache hits)
      later_times = Enum.take(compilation_times, -5)
      earlier_times = Enum.take(compilation_times, 5)

      avg_later = Enum.sum(later_times) / length(later_times)
      avg_earlier = Enum.sum(earlier_times) / length(earlier_times)

      # Later compilations should generally be faster due to caching
      assert avg_later < avg_earlier * 1.5, "Expected performance improvement over time"
    end

    @tag :stress
    test "concurrent compilation performance", %{sandbox_dir: sandbox_dir} do
      create_simple_project(sandbox_dir, 5)

      # Initial compilation
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Perform concurrent incremental compilations
      tasks =
        for i <- 1..5 do
          Task.async(fn ->
            {time, result} =
              :timer.tc(fn ->
                IsolatedCompiler.incremental_compile(sandbox_dir)
              end)

            {i, time, result}
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should complete successfully
      Enum.each(results, fn {_i, _time, result} ->
        assert {:ok, compile_info} = result
        assert compile_info.cache_hit == true
      end)

      # All should be fast (cache hits)
      times = Enum.map(results, fn {_i, time, _result} -> time end)
      max_time = Enum.max(times)

      assert max_time < 200_000,
             "Concurrent cache access took #{max_time / 1000}ms, expected < 200ms"
    end
  end

  describe "stress testing compilation system" do
    @tag :stress
    test "handles rapid file changes efficiently", %{sandbox_dir: sandbox_dir} do
      create_simple_project(sandbox_dir, 10)

      # Initial compilation
      assert {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

      # Perform rapid file modifications and compilations
      start_time = System.monotonic_time(:millisecond)

      results =
        for i <- 1..20 do
          # Modify a random file
          module_num = rem(i, 10) + 1

          modify_single_module(
            sandbox_dir,
            "Module#{module_num}",
            "def rapid_func_#{i}, do: #{i}"
          )

          case IsolatedCompiler.incremental_compile(sandbox_dir) do
            {:ok, result} -> {:ok, result}
            error -> error
          end
        end

      end_time = System.monotonic_time(:millisecond)
      total_time = end_time - start_time

      # All compilations should succeed
      successful_compilations =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      assert successful_compilations >= 18,
             "Expected at least 18/20 successful compilations, got #{successful_compilations}"

      # Should handle rapid changes efficiently
      assert total_time < 10_000, "Rapid changes took #{total_time}ms, expected < 10000ms"

      # Most should be incremental
      incremental_count =
        results
        |> Enum.count(fn
          {:ok, result} -> result.incremental == true
          _ -> false
        end)

      assert incremental_count >= 15,
             "Expected at least 15 incremental compilations, got #{incremental_count}"
    end

    @tag :stress
    test "memory usage remains stable during repeated compilations", %{sandbox_dir: sandbox_dir} do
      create_simple_project(sandbox_dir, 5)

      # Measure memory usage during repeated compilations
      assert_memory_usage_stable(
        fn ->
          # Initial compilation
          {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

          # Perform many incremental compilations
          for i <- 1..50 do
            if rem(i, 10) == 0 do
              # Modify file occasionally
              modify_single_module(sandbox_dir, "Module1", "def memory_test_#{i}, do: #{i}")
            end

            {:ok, _} = IsolatedCompiler.incremental_compile(sandbox_dir)
          end
        end,
        # 10% memory tolerance
        0.1
      )
    end

    @tag :stress
    test "no process leaks during compilation operations", %{sandbox_dir: sandbox_dir} do
      create_simple_project(sandbox_dir, 3)

      assert_no_process_leaks(fn ->
        # Perform various compilation operations
        {:ok, _} = IsolatedCompiler.compile_sandbox(sandbox_dir)

        for i <- 1..10 do
          modify_single_module(sandbox_dir, "Module1", "def leak_test_#{i}, do: #{i}")
          {:ok, _} = IsolatedCompiler.incremental_compile(sandbox_dir)
        end

        # Clear cache
        :ok = IsolatedCompiler.clear_compilation_cache(sandbox_dir)
      end)
    end
  end

  # Helper functions

  defp create_temp_sandbox do
    temp_dir = System.tmp_dir!()
    sandbox_name = unique_id("perf_test_sandbox")
    sandbox_dir = Path.join(temp_dir, sandbox_name)

    File.mkdir_p!(sandbox_dir)
    File.mkdir_p!(Path.join(sandbox_dir, "lib"))

    # Create a basic mix.exs
    mix_content = """
    defmodule PerfTestSandbox.MixProject do
      use Mix.Project
      
      def project do
        [
          app: :perf_test_sandbox,
          version: "0.1.0",
          elixir: "~> 1.14"
        ]
      end
    end
    """

    File.write!(Path.join(sandbox_dir, "mix.exs"), mix_content)

    sandbox_dir
  end

  defp create_simple_project(sandbox_dir, module_count) do
    for i <- 1..module_count do
      create_sample_module(sandbox_dir, "Module#{i}", """
      def simple_func_#{i}, do: #{i}
      def other_func_#{i}(x), do: x + #{i}
      """)
    end
  end

  defp create_complex_project(sandbox_dir, module_count) do
    for i <- 1..module_count do
      content = """
      @moduledoc "Module #{i} for performance testing"

      def complex_func_#{i}(x) when is_integer(x) do
        1..x
        |> Enum.map(&(&1 * #{i}))
        |> Enum.sum()
      end

      def complex_func_#{i}(x) when is_list(x) do
        Enum.map(x, &(&1 + #{i}))
      end

      def helper_func_#{i}(a, b, c) do
        {a + #{i}, b * #{i}, c - #{i}}
      end

      defstruct [:field_#{i}, :other_field_#{i}]
      """

      create_sample_module(sandbox_dir, "Module#{i}", content)
    end
  end

  defp create_function_heavy_project(sandbox_dir) do
    for i <- 1..5 do
      functions =
        for j <- 1..10 do
          "def func_#{i}_#{j}(x), do: x + #{i * j}"
        end
        |> Enum.join("\n  ")

      create_sample_module(sandbox_dir, "FunctionModule#{i}", functions)
    end
  end

  defp create_dependency_heavy_project(sandbox_dir) do
    # Create base module
    create_sample_module(sandbox_dir, "BaseModule", """
    def base_value, do: 42
    def base_transform(x), do: x * 2
    """)

    # Create modules that depend on base
    for i <- 1..8 do
      content = """
      alias BaseModule

      def dependent_func_#{i} do
        BaseModule.base_value() + #{i}
      end

      def transform_#{i}(x) do
        BaseModule.base_transform(x) + #{i}
      end
      """

      create_sample_module(sandbox_dir, "DependentModule#{i}", content)
    end

    # Create modules that depend on dependent modules
    for i <- 1..3 do
      deps = Enum.map(1..3, fn j -> "DependentModule#{j}" end)
      aliases = Enum.map_join(deps, "\n  ", fn dep -> "alias #{dep}" end)

      content = """
      #{aliases}

      def chain_func_#{i} do
        #{Enum.at(deps, 0)}.dependent_func_1() + 
        #{Enum.at(deps, 1)}.dependent_func_2() + 
        #{Enum.at(deps, 2)}.dependent_func_3()
      end
      """

      create_sample_module(sandbox_dir, "ChainModule#{i}", content)
    end
  end

  defp modify_single_module(sandbox_dir, module_name, additional_content) do
    file_name = module_name |> Macro.underscore() |> Kernel.<>(".ex")
    file_path = Path.join([sandbox_dir, "lib", file_name])

    if File.exists?(file_path) do
      current_content = File.read!(file_path)

      # Insert new content before the final 'end'
      new_content = String.replace(current_content, ~r/end\s*$/, "  #{additional_content}\nend")
      File.write!(file_path, new_content)
    else
      create_sample_module(sandbox_dir, module_name, additional_content)
    end

    bump_mtime(file_path)
    file_path
  end

  defp modify_function_bodies(sandbox_dir) do
    # Modify function bodies in function-heavy modules
    for i <- 1..3 do
      module_name = "FunctionModule#{i}"
      file_name = module_name |> Macro.underscore() |> Kernel.<>(".ex")
      file_path = Path.join([sandbox_dir, "lib", file_name])

      if File.exists?(file_path) do
        content = File.read!(file_path)
        # Change function implementations but keep signatures
        modified_content = String.replace(content, ~r/x \+ (\d+)/, "x * \\1 + 1")
        File.write!(file_path, modified_content)
        bump_mtime(file_path)
      end
    end
  end

  defp modify_base_module(sandbox_dir) do
    modify_single_module(sandbox_dir, "BaseModule", """
    def new_base_func, do: :modified
    """)
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

  defp bump_mtime(file_path) do
    {:ok, %File.Stat{mtime: current_mtime}} = File.stat(file_path)

    current_seconds = :calendar.datetime_to_gregorian_seconds(current_mtime)
    now_seconds = :calendar.datetime_to_gregorian_seconds(:calendar.universal_time())
    target_seconds = max(current_seconds, now_seconds) + 1

    File.touch!(file_path, :calendar.gregorian_seconds_to_datetime(target_seconds))
  end
end
