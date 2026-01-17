defmodule Sandbox.TestHelpers do
  import ExUnit.Assertions

  def unique_id(prefix) when is_binary(prefix) do
    suffix = System.unique_integer([:positive])
    "#{prefix}-#{suffix}"
  end

  def fixture_path do
    Path.expand("../fixtures/simple_sandbox", __DIR__)
  end

  def ensure_fixture_tree do
    fixture_path = fixture_path()

    unless File.exists?(fixture_path) do
      File.mkdir_p!(fixture_path)
      File.mkdir_p!(Path.join(fixture_path, "lib"))

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

      module_content = """
      defmodule SimpleSandbox do
        def hello do
          :world
        end
      end
      """

      File.write!(Path.join([fixture_path, "lib", "simple_sandbox.ex"]), module_content)
    end

    fixture_path
  end

  def create_temp_dir(prefix) when is_binary(prefix) do
    dir = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  def write_mix_project(dir, module_name, app_name, opts \\ [])
      when is_binary(dir) and is_binary(module_name) and is_atom(app_name) do
    version = Keyword.get(opts, :version, "0.1.0")
    elixir = Keyword.get(opts, :elixir, "~> 1.14")

    mix_content = """
    defmodule #{module_name}.MixProject do
      use Mix.Project

      def project do
        [
          app: #{inspect(app_name)},
          version: "#{version}",
          elixir: "#{elixir}"
        ]
      end

      def application do
        [
          extra_applications: [:logger]
        ]
      end
    end
    """

    File.write!(Path.join(dir, "mix.exs"), mix_content)
  end

  def write_module_file(dir, relative_path, content)
      when is_binary(dir) and is_binary(relative_path) and is_binary(content) do
    full_path = Path.join(dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
  end

  def await(fun, opts \\ []) when is_function(fun, 0) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 10)
    description = Keyword.get(opts, :description, "condition")
    deadline = System.monotonic_time(:millisecond) + timeout

    do_await(fun, deadline, interval, description)
  end

  defp do_await(fun, deadline, interval, description) do
    case fun.() do
      true ->
        :ok

      :ok ->
        :ok

      {:ok, _value} = ok ->
        ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("Timed out waiting for #{description}")
        else
          receive do
          after
            interval -> :ok
          end

          do_await(fun, deadline, interval, description)
        end
    end
  end
end
