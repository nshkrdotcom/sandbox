defmodule Sandbox.SerialCase do
  defmacro __using__(opts) do
    telemetry_isolation = Keyword.get(opts, :telemetry_isolation, true)
    logger_isolation = Keyword.get(opts, :logger_isolation, true)
    ets_isolation = Keyword.get(opts, :ets_isolation, [])

    quote do
      use ExUnit.Case, async: false

      setup context do
        {:ok, base_context} =
          Supertester.UnifiedTestFoundation.setup_isolation(:basic, context)

        isolation_context = base_context.isolation_context

        isolation_context =
          if unquote(telemetry_isolation) do
            {:ok, _test_id, ctx} =
              Supertester.TelemetryHelpers.setup_telemetry_isolation(isolation_context)

            ctx
          else
            isolation_context
          end

        isolation_context =
          if unquote(logger_isolation) do
            {:ok, ctx} = Supertester.LoggerIsolation.setup_logger_isolation(isolation_context)

            if level = context[:logger_level] do
              Supertester.LoggerIsolation.isolate_level(level)
            end

            ctx
          else
            isolation_context
          end

        isolation_context =
          if unquote(ets_isolation) != [] do
            {:ok, ctx} =
              Supertester.ETSIsolation.setup_ets_isolation(
                isolation_context,
                unquote(ets_isolation)
              )

            ctx
          else
            isolation_context
          end

        if events = context[:telemetry_events] do
          Supertester.TelemetryHelpers.attach_isolated(events)
        end

        if tables = context[:ets_tables] do
          tables
          |> List.wrap()
          |> Enum.each(fn table ->
            {:ok, _} = Supertester.ETSIsolation.mirror_table(table)
          end)
        end

        {:ok, %{base_context | isolation_context: isolation_context}}
      end

      import Sandbox.TestHelpers
      import Supertester.Assertions
      import Supertester.GenServerHelpers
      import Supertester.OTPHelpers
      import Supertester.SupervisorHelpers
    end
  end
end
