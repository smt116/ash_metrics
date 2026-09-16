defmodule AshMetrics do
  @moduledoc """
  Declarative business metrics for Ash resources.

  `AshMetrics` is an `Ash.Resource` extension that adds a `metrics do` block in
  which counters and distributions are declared next to the action they describe
  and validated at compile time. Those declarations compile to
  `Telemetry.Metrics` definitions rather than to a new emit/aggregate/export
  pipeline, so the host application's existing reporter is what actually ships
  them to a backend.

      defmodule MyApp.Mailings.TemplatedDelivery do
        use Ash.Resource,
          domain: MyApp.Mailings,
          extensions: [AshMetrics]

        metrics do
          name :templated_delivery

          counter :delivery,
            outcomes: [:queued, :sent, :bounced, :delivered, :error],
            tags: [:provider, :template]
        end
      end

  See `AshMetrics.Dsl` for the section definition and `AshMetrics.Info` for
  introspection.
  """

  use Spark.Dsl.Extension, sections: [AshMetrics.Dsl.metrics()]
end
