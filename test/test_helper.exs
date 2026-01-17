# Setup Elixir runtime for tests
Sandbox.Test.CompilationHelper.setup_elixir_runtime()

# Suppress expected module redefinition warnings for sandbox isolation testing
Code.compiler_options(ignore_module_conflict: true)

# Configure custom warning filter for sandbox-related warnings
defmodule TestWarningFilter do
  @filtered_modules ~w(BaseModule DependentModule ModuleA ModuleB HashModule ForceModule ProcessDemo)

  def filter_warnings do
    # Capture the original warning handler
    original_handler = Process.get(:elixir_compiler_warning_handler)

    # Set up our custom warning filter
    Process.put(:elixir_compiler_warning_handler, fn file, line, warning ->
      # Filter out expected sandbox module redefinitions
      unless sandbox_redefinition_warning?(file, warning) do
        forward_warning(original_handler, file, line, warning)
      end
    end)
  end

  defp sandbox_redefinition_warning?(file, warning) do
    String.contains?(warning, "redefining module") and
      (String.contains?(file, "/tmp/") or mentions_filtered_module?(warning))
  end

  defp mentions_filtered_module?(warning) do
    Enum.any?(@filtered_modules, &String.contains?(warning, &1))
  end

  defp forward_warning(nil, file, line, warning) do
    IO.warn(warning, file: file, line: line)
  end

  defp forward_warning(handler, file, line, warning) do
    handler.(file, line, warning)
  end
end

# Apply the warning filter
TestWarningFilter.filter_warnings()

# Configure ExUnit
ExUnit.configure(
  exclude: [:pending, :performance],
  capture_log: true
)

ExUnit.start()

# Configure Supertester for OTP-compliant testing
Application.ensure_all_started(:supertester)

# Ensure the sandbox application is started
_log =
  ExUnit.CaptureLog.capture_log(fn ->
    {:ok, _} = Application.ensure_all_started(:sandbox)
  end)
