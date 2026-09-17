defmodule AshMetrics.ObserveTest.ProviderFromMetadata do
  @moduledoc false
  # Supplies a tag that the resource also declares, so that the precedence of
  # call-site tags over extracted ones is observable.

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  def tag_keys, do: [:provider]

  @impl AshMetrics.TagExtractor
  def extract(metadata), do: %{provider: Map.get(metadata, :provider)}
end

defmodule AshMetrics.ObserveTest do
  # Swaps the configured tag extractor, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.ObserveTest.ProviderFromMetadata
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.Shipment

  setup do
    handler = "ash-metrics-observe-#{System.unique_integer([:positive])}"
    test_process = self()
    original = Application.get_env(:ash_metrics, :tag_extractor)

    :telemetry.attach_many(
      handler,
      [
        AshMetrics.event_name(Delivery, :send_latency),
        AshMetrics.event_name(Invoice, :settlement_lag),
        AshMetrics.event_name(Shipment, :transit_time)
      ],
      &__MODULE__.handle_event/4,
      %{pid: test_process}
    )

    on_exit(fn ->
      :telemetry.detach(handler)

      case original do
        nil -> Application.delete_env(:ash_metrics, :tag_extractor)
        extractor -> Application.put_env(:ash_metrics, :tag_extractor, extractor)
      end
    end)

    :ok
  end

  def handle_event(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:emitted, event, measurements, metadata})

    :ok
  end

  describe "observe/4" do
    test "emits the event name and the observed value" do
      assert AshMetrics.observe(Delivery, :send_latency, 142) == :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Delivery, :send_latency]
      assert measurements == %{value: 142}
      assert metadata == %{}
    end

    test "records a float unchanged" do
      AshMetrics.observe(Delivery, :send_latency, 12.5)

      assert_received {:emitted, _event, %{value: 12.5}, _metadata}
    end

    test "carries declared call-site tags" do
      AshMetrics.observe(Delivery, :send_latency, 10, tags: %{provider: "ses"})

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{provider: "ses"}
    end

    test "carries tags the extractor derives from metadata" do
      AshMetrics.observe(Delivery, :send_latency, 10, metadata: %{tenant: "acme"})

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{tenant: "acme"}
    end

    test "call-site tags win over extracted ones" do
      Application.put_env(:ash_metrics, :tag_extractor, ProviderFromMetadata)

      AshMetrics.observe(Delivery, :send_latency, 10,
        tags: %{provider: "explicit"},
        metadata: %{provider: "extracted"}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{provider: "explicit"}
    end

    test "works for a distribution that declares no tags" do
      assert AshMetrics.observe(Invoice, :settlement_lag, 3) == :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Invoice, :settlement_lag]
      assert measurements == %{value: 3}
      assert metadata == %{}
    end

    test "raises when the value is not a number" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.observe(Delivery, :send_latency, "142")
        end

      assert error.message ==
               ~s(observe/4 records a number, got: "142". Distribution :send_latency ) <>
                 "on AshMetrics.Test.Delivery cannot record anything else."
    end

    test "raises when the metric is a counter" do
      error = assert_raise ArgumentError, fn -> AshMetrics.observe(Delivery, :delivery, 1) end

      assert error.message ==
               ":delivery on AshMetrics.Test.Delivery is a counter, not a " <>
                 "distribution. Use `increment/3` to emit a counter."
    end

    test "raises when the metric is a gauge" do
      error = assert_raise ArgumentError, fn -> AshMetrics.observe(Job, :backlog, 1) end

      assert error.message ==
               ":backlog on AshMetrics.Test.Job is a gauge, not a distribution. A " <>
                 "gauge is polled by AshMetrics itself and has no call site."
    end

    test "raises when the metric is not declared" do
      assert_raise ArgumentError, ~r/no metric :nope is declared/, fn ->
        AshMetrics.observe(Delivery, :nope, 1)
      end
    end

    test "raises when a tag is not declared, naming it and the declared tags" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.observe(Delivery, :send_latency, 10, tags: %{region: "eu"})
        end

      assert error.message ==
               ":region is not a declared tag of distribution :send_latency on " <>
                 "AshMetrics.Test.Delivery. Declared tags: :provider"
    end

    test "emits nothing when validation fails" do
      assert_raise ArgumentError, fn ->
        AshMetrics.observe(Delivery, :send_latency, 10, tags: %{region: "eu"})
      end

      refute_received {:emitted, _event, _measurements, _metadata}
    end
  end

  describe "observe/4 with closed tags" do
    test "carries a closed tag and an open one" do
      assert AshMetrics.observe(Shipment, :transit_time, 42, tags: %{carrier: :ups, region: "eu"}) ==
               :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Shipment, :transit_time]
      assert measurements == %{value: 42}
      assert metadata == %{carrier: :ups, region: "eu"}
    end

    test "leaves an open tag optional" do
      AshMetrics.observe(Shipment, :transit_time, 42, tags: %{carrier: :dhl})

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{carrier: :dhl}
    end

    test "raises when a closed tag is missing, naming it and its declared values" do
      error =
        assert_raise ArgumentError, fn -> AshMetrics.observe(Shipment, :transit_time, 42) end

      assert error.message ==
               ":carrier is a required tag of distribution :transit_time on " <>
                 "AshMetrics.Test.Shipment. Declared values: :ups, :dhl"
    end

    test "raises when a closed tag's value is not declared" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.observe(Shipment, :transit_time, 42, tags: %{carrier: :fedex})
        end

      assert error.message ==
               ":fedex is not a declared value of the tag :carrier of distribution " <>
                 ":transit_time on AshMetrics.Test.Shipment. Declared values: :ups, :dhl"
    end
  end
end
