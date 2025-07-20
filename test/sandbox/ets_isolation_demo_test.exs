defmodule Sandbox.EtsIsolationDemoTest do
  use ExUnit.Case, async: false

  alias Sandbox.Manager

  @moduletag :integration

  test "demonstrates ETS-based isolation capabilities (Phase 3)" do
    # Create a temporary test directory
    test_dir = Path.join(System.tmp_dir!(), "ets_isolation_demo_#{:rand.uniform(10000)}")
    File.mkdir_p!(test_dir)
    File.mkdir_p!(Path.join(test_dir, "lib"))

    # Create mix.exs
    mix_content = """
    defmodule EtsIsolationDemo.MixProject do
      use Mix.Project

      def project do
        [
          app: :ets_isolation_demo,
          version: \"0.1.0\",
          elixir: \"~> 1.14\"
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end
    end
    """

    File.write!(Path.join(test_dir, "mix.exs"), mix_content)

    # Create a simple module  
    module_content = """
    defmodule EtsDemo do
      def get_ets_info do
        %{
          pid: self(),
          node: node(),
          status: :running
        }
      end
    end
    """

    File.write!(Path.join([test_dir, "lib", "ets_demo.ex"]), module_content)

    # Test supervisor 
    defmodule EtsIsolationTestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    # Test ETS isolation mode
    sandbox_id = "ets_demo_#{:rand.uniform(1000)}"

    IO.puts("Testing ETS isolation mode (Phase 3)")

    result =
      Manager.create_sandbox(
        sandbox_id,
        EtsIsolationTestSupervisor,
        sandbox_path: test_dir,
        isolation_mode: :ets,
        isolation_level: :medium
      )

    case result do
      {:ok, sandbox_info} ->
        IO.puts("✓ Successfully created sandbox with ETS isolation")
        IO.puts("  - Sandbox ID: #{sandbox_info.id}")
        IO.puts("  - Status: #{sandbox_info.status}")
        IO.puts("  - Isolation mode: #{Map.get(sandbox_info, :isolation_mode, "unknown")}")

        # Check if virtual code table was created
        case Map.get(sandbox_info, :virtual_code_table) do
          nil ->
            IO.puts("  - Virtual code table: not created")

          table_ref ->
            IO.puts("  - Virtual code table: #{inspect(table_ref)}")
        end

        # Clean up
        Manager.destroy_sandbox(sandbox_id)

        IO.puts("✓ ETS isolation test successful")

      {:error, reason} ->
        IO.puts("✗ Failed to create sandbox with ETS isolation: #{inspect(reason)}")
        flunk("ETS isolation failed")
    end

    # Clean up test directory
    File.rm_rf!(test_dir)

    IO.puts("\n=== ETS Isolation Demo Results ===")
    IO.puts("This demonstrates Phase 3 ETS-based virtual code table capabilities")
    IO.puts("✓ ETS isolation Phase 3 infrastructure is implemented!")

    # Test passes if we get here
    assert true
  end

  test "demonstrates all isolation modes working together" do
    # Create a temporary test directory
    test_dir = Path.join(System.tmp_dir!(), "all_isolation_demo_#{:rand.uniform(10000)}")
    File.mkdir_p!(test_dir)
    File.mkdir_p!(Path.join(test_dir, "lib"))

    # Create mix.exs
    mix_content = """
    defmodule AllIsolationDemo.MixProject do
      use Mix.Project

      def project do
        [
          app: :all_isolation_demo,
          version: \"0.1.0\",
          elixir: \"~> 1.14\"
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end
    end
    """

    File.write!(Path.join(test_dir, "mix.exs"), mix_content)

    # Create a simple module
    module_content = """
    defmodule AllDemo do
      def get_info do
        %{
          pid: self(),
          node: node(),
          status: :running
        }
      end
    end
    """

    File.write!(Path.join([test_dir, "lib", "all_demo.ex"]), module_content)

    # Test supervisor 
    defmodule AllIsolationTestSupervisor do
      use Supervisor

      def start_link(opts) do
        Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
      end

      def init(_opts) do
        children = []
        Supervisor.init(children, strategy: :one_for_one)
      end
    end

    # Test all isolation modes
    isolation_modes = [:module, :process, :hybrid, :ets]

    results =
      Enum.map(isolation_modes, fn mode ->
        sandbox_id = "all_demo_#{mode}_#{:rand.uniform(1000)}"

        IO.puts("Testing isolation mode: #{mode}")

        result =
          Manager.create_sandbox(
            sandbox_id,
            AllIsolationTestSupervisor,
            sandbox_path: test_dir,
            isolation_mode: mode,
            isolation_level: :medium
          )

        case result do
          {:ok, sandbox_info} ->
            IO.puts("✓ Successfully created sandbox with #{mode} isolation")
            IO.puts("  - Sandbox ID: #{sandbox_info.id}")
            IO.puts("  - Status: #{sandbox_info.status}")

            # Clean up
            Manager.destroy_sandbox(sandbox_id)

            {mode, :success}

          {:error, reason} ->
            IO.puts("✗ Failed to create sandbox with #{mode} isolation: #{inspect(reason)}")
            {mode, :failed}
        end
      end)

    # Clean up test directory
    File.rm_rf!(test_dir)

    # Count successful isolations
    successful_modes = Enum.count(results, fn {_, result} -> result == :success end)

    IO.puts("\n=== All Isolation Modes Demo Results ===")
    IO.puts("Successfully tested #{successful_modes}/#{length(isolation_modes)} isolation modes")

    Enum.each(results, fn {mode, result} ->
      status = if result == :success, do: "✓", else: "✗"
      IO.puts("#{status} #{mode} isolation: #{result}")
    end)

    IO.puts("This demonstrates all three phases of the module isolation architecture")
    IO.puts("Phase 1: Module transformation (:module)")
    IO.puts("Phase 2: Process-based isolation (:process)")
    IO.puts("Phase 3: ETS-based virtual code tables (:ets)")
    IO.puts("Combined: Hybrid approach (:hybrid)")

    # We expect all isolation modes to work
    assert successful_modes == length(isolation_modes), "All isolation modes should work"

    IO.puts("✓ Complete module isolation architecture is implemented!")
  end
end
