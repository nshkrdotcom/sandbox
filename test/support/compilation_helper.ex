defmodule Sandbox.Test.CompilationHelper do
  @moduledoc """
  Helper module to ensure proper Elixir runtime access in tests.
  """

  @doc """
  Sets up the test environment with proper Elixir runtime paths.
  """
  def setup_elixir_runtime do
    # Get the current Elixir executable path
    elixir_root = :code.root_dir() |> to_string()
    elixir_bin = Path.join([elixir_root, "bin"])

    # Add Elixir bin to PATH if not already there
    current_path = System.get_env("PATH", "")

    unless String.contains?(current_path, elixir_bin) do
      System.put_env("PATH", "#{elixir_bin}:#{current_path}")
    end

    # Ensure ELIXIR_ERL_OPTIONS is set for proper module loading
    System.put_env("ELIXIR_ERL_OPTIONS", "+fnu")

    # Set ERL_LIBS to include Elixir's lib directory
    erl_libs = Path.join([elixir_root, "lib", "elixir", "lib"])
    System.put_env("ERL_LIBS", erl_libs)

    :ok
  end

  @doc """
  Creates a minimal Elixir script that can be used to compile code.
  """
  def create_elixir_compiler_script(target_dir) do
    script_path = Path.join(target_dir, "elixir_compiler.exs")

    script_content = """
    # Minimal Elixir compiler script
    [source_path, output_path | _rest] = System.argv()

    # Find all .ex files
    files = Path.wildcard(Path.join(source_path, "**/*.ex"))

    # Compile them
    case Kernel.ParallelCompiler.compile_to_path(files, output_path) do
      {:ok, modules, []} ->
        IO.puts("Compiled \#{length(modules)} modules")
        System.halt(0)
        
      {:ok, modules, warnings} ->
        IO.puts("Compiled \#{length(modules)} modules with \#{length(warnings)} warnings")
        Enum.each(warnings, &IO.puts(:stderr, inspect(&1)))
        System.halt(0)
        
      {:error, errors, warnings} ->
        IO.puts(:stderr, "Compilation failed with \#{length(errors)} errors")
        Enum.each(errors, &IO.puts(:stderr, inspect(&1)))
        Enum.each(warnings, &IO.puts(:stderr, inspect(&1)))
        System.halt(1)
    end
    """

    File.write!(script_path, script_content)
    script_path
  end

  @doc """
  Provides an alternative elixir command that works in restricted environments.
  """
  def elixir_command(args, opts \\ []) do
    # Use escript to run Elixir code directly
    escript_path = System.find_executable("escript")

    if escript_path do
      # Create a temporary escript
      temp_script = create_temp_escript(args)

      try do
        System.cmd(escript_path, [temp_script], opts)
      after
        File.rm(temp_script)
      end
    else
      # Fallback to using Erlang directly
      erl_path = System.find_executable("erl") || "erl"

      # Build Erlang arguments to start Elixir
      erl_args = [
        "-noshell",
        "-s",
        "elixir",
        "start_cli",
        "-extra" | args
      ]

      System.cmd(erl_path, erl_args, opts)
    end
  end

  defp create_temp_escript(_args) do
    temp_path = Path.join(System.tmp_dir!(), "elixir_#{:rand.uniform(1_000_000)}.escript")

    # Get Elixir ebin path without using deprecated function
    elixir_ebin = Path.join(:code.lib_dir(:elixir), "ebin")

    escript_content = """
    #!/usr/bin/env escript
    %% -*- erlang -*-
    %%! -pa #{elixir_ebin}

    main(Args) ->
        elixir:start_cli(Args).
    """

    File.write!(temp_path, escript_content)
    File.chmod!(temp_path, 0o755)
    temp_path
  end
end
