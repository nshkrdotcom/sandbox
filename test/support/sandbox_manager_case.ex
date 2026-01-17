defmodule Sandbox.ManagerCase do
  @moduledoc false
  defmacro __using__(opts) do
    isolation = Keyword.get(opts, :isolation, :full_isolation)
    telemetry_isolation = Keyword.get(opts, :telemetry_isolation, true)
    logger_isolation = Keyword.get(opts, :logger_isolation, true)
    ets_isolation = Keyword.get(opts, :ets_isolation, [])

    quote do
      use Supertester.ExUnitFoundation,
        isolation: unquote(isolation),
        telemetry_isolation: unquote(telemetry_isolation),
        logger_isolation: unquote(logger_isolation),
        ets_isolation: unquote(ets_isolation)

      import Sandbox.TestHelpers
      import Supertester.Assertions
      import Supertester.GenServerHelpers
      import Supertester.OTPHelpers
      import Supertester.SupervisorHelpers

      setup _context do
        {:ok, services} = Sandbox.TestHelpers.start_isolated_services()
        {:ok, services}
      end
    end
  end
end
