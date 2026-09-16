defmodule AshMetrics.MetricsTest.Renaming do
  @moduledoc false
  # A backend that rewrites the compiled definitions, to prove that the
  # optional callback is applied.

  @spec transform_metrics([Telemetry.Metrics.t()], keyword()) :: [Telemetry.Metrics.t()]
  def transform_metrics(metrics, _opts) do
    Enum.map(metrics, &%{&1 | description: "rewritten"})
  end
end

defmodule AshMetrics.MetricsTest.Silent do
  @moduledoc false
  # A backend with no `transform_metrics/2`, which must be left alone rather
  # than crashing the compilation of the definitions.
end

defmodule AshMetrics.MetricsTest do
  # Swaps the configured backend, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.MetricsTest.Renaming
  alias AshMetrics.MetricsTest.Silent
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Plain
  alias Telemetry.Metrics.Counter
  alias Telemetry.Metrics.Distribution

  setup do
    original = Application.get_env(:ash_metrics, :backend)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, :backend)
        backend -> Application.put_env(:ash_metrics, :backend, backend)
      end
    end)

    :ok
  end

  describe "metrics_for/1" do
    test "compiles a counter into a Telemetry.Metrics.Counter" do
      assert [%Counter{} = counter, %Distribution{}] = AshMetrics.metrics_for([Delivery])

      assert counter.name == [:test, :mailings, :templated_delivery, :delivery, :count]
      assert counter.event_name == [:ash_metrics, Delivery, :delivery]
      assert counter.measurement == :count
      assert counter.tags == [:outcome, :provider, :template, :tenant]
      assert counter.description == "Templated deliveries by outcome"
      assert counter.unit == :unit
      assert counter.reporter_options == []
    end

    test "compiles a distribution into a Telemetry.Metrics.Distribution" do
      assert [%Counter{}, %Distribution{} = distribution] = AshMetrics.metrics_for([Delivery])

      assert distribution.name == [
               :test,
               :mailings,
               :templated_delivery,
               :send_latency,
               :duration
             ]

      assert distribution.event_name == [:ash_metrics, Delivery, :send_latency]
      assert distribution.tags == [:provider, :tenant]
      assert distribution.description == "Time from enqueue to provider acknowledgement"
      assert distribution.reporter_options == [buckets: [10, 50, 100, 250, 500]]
    end

    test "resolves a unit conversion into the target unit and a converting measurement" do
      assert [_counter, %Distribution{} = distribution] = AshMetrics.metrics_for([Delivery])

      assert distribution.unit == :millisecond
      assert is_function(distribution.measurement, 1)

      native_millisecond = System.convert_time_unit(1, :millisecond, :native)

      assert distribution.measurement.(%{value: native_millisecond}) == 1
    end

    test "omits reporter options when a distribution declares no buckets" do
      assert [%Counter{}, %Distribution{} = distribution] = AshMetrics.metrics_for([Invoice])

      assert distribution.name == [:test, :mailings, :invoice, :settlement_lag, :duration]
      assert distribution.measurement == :value
      assert distribution.unit == :unit
      assert distribution.tags == [:tenant]
      assert distribution.reporter_options == []
    end

    test "tags a counter with no declared tags with the outcome and extractor keys only" do
      assert [%Counter{tags: [:outcome, :tenant]}, %Distribution{}] =
               AshMetrics.metrics_for([Invoice])
    end

    test "skips a resource that does not use the extension" do
      assert AshMetrics.metrics_for([Plain]) == []
      assert length(AshMetrics.metrics_for([Plain, Invoice])) == 2
    end

    test "returns an empty list for no resources" do
      assert AshMetrics.metrics_for([]) == []
    end

    test "applies the backend's transform_metrics/2 when it exports one" do
      Application.put_env(:ash_metrics, :backend, Renaming)

      assert Enum.map(AshMetrics.metrics_for([Invoice]), & &1.description) == [
               "rewritten",
               "rewritten"
             ]
    end

    test "leaves the definitions alone when the backend exports no transform" do
      Application.put_env(:ash_metrics, :backend, Silent)

      assert Enum.map(AshMetrics.metrics_for([Invoice]), & &1.description) == [nil, nil]
    end

    test "leaves the definitions alone when the configured backend does not exist" do
      Application.put_env(:ash_metrics, :backend, AshMetrics.MetricsTest.Absent)

      assert Enum.map(AshMetrics.metrics_for([Invoice]), & &1.description) == [nil, nil]
    end
  end

  describe "metrics/0" do
    test "finds every resource of the configured application's domains" do
      names = Enum.map(AshMetrics.metrics(), & &1.name)

      assert names == [
               [:test, :mailings, :templated_delivery, :delivery, :count],
               [:test, :mailings, :templated_delivery, :send_latency, :duration],
               [:test, :mailings, :invoice, :capture, :count],
               [:test, :mailings, :invoice, :settlement_lag, :duration]
             ]
    end

    test "ignores the resource that does not use the extension" do
      refute Enum.any?(AshMetrics.metrics(), &(Plain == Enum.at(&1.event_name, 1)))
    end

    test "raises when no otp_app is configured" do
      original = Application.get_env(:ash_metrics, :otp_app)
      Application.delete_env(:ash_metrics, :otp_app)
      on_exit(fn -> Application.put_env(:ash_metrics, :otp_app, original) end)

      assert_raise ArgumentError, ~r/`otp_app` must be set/, fn -> AshMetrics.metrics() end
    end
  end
end
