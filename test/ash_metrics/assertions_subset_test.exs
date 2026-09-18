defmodule AshMetrics.AssertionsSubsetTest do
  # Attaches handlers for globally visible `:telemetry` events.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Invoice]

  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice

  test "attaches only to the metrics of the given resources" do
    AshMetrics.increment(Invoice, :capture)
    AshMetrics.increment(Delivery, :delivery, tags: %{status: :sent})

    assert_metric_emitted("test.mailings.invoice.capture")
    refute_metric_emitted("test.mailings.templated_delivery.delivery")
  end
end
