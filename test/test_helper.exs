# Setup Elixir runtime for tests
Sandbox.Test.CompilationHelper.setup_elixir_runtime()

# Suppress expected module redefinition warnings for sandbox isolation testing
Code.compiler_options(ignore_module_conflict: true)

# Configure custom warning filter for sandbox-related warnings
defmodule TestWarningFilter do
  def filter_warnings do
    # Capture the original warning handler
    original_handler = Process.get(:elixir_compiler_warning_handler)
    
    # Set up our custom warning filter
    Process.put(:elixir_compiler_warning_handler, fn file, line, warning ->
      # Filter out expected sandbox module redefinitions
      unless String.contains?(warning, "redefining module") and 
             (String.contains?(file, "/tmp/") or 
              String.contains?(warning, "BaseModule") or
              String.contains?(warning, "DependentModule") or
              String.contains?(warning, "ModuleA") or
              String.contains?(warning, "ModuleB") or
              String.contains?(warning, "HashModule") or
              String.contains?(warning, "ForceModule") or
              String.contains?(warning, "ProcessDemo")) do
        # Pass through other warnings to the original handler
        if original_handler do
          original_handler.(file, line, warning)
        else
          IO.warn(warning, file: file, line: line)
        end
      end
    end)
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
{:ok, _} = Application.ensure_all_started(:sandbox)
