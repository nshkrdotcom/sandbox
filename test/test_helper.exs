# Ensure compilation helper is available
Code.require_file("support/compilation_helper.ex", __DIR__)

# Setup Elixir runtime for tests
Sandbox.Test.CompilationHelper.setup_elixir_runtime()

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
