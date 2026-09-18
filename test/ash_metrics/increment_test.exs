defmodule AshMetrics.IncrementTest.ProviderFromMetadata do
  @moduledoc false
  # Supplies a tag that the resource also declares, so that the precedence of
  # call-site tags over extracted ones is observable.

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  def tag_keys, do: [:provider]

  @impl AshMetrics.TagExtractor
  def extract(metadata), do: %{provider: Map.get(metadata, :provider)}
end

defmodule AshMetrics.IncrementTest do
  # Swaps the configured tag extractor, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.IncrementTest.ProviderFromMetadata
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.Plain
  alias AshMetrics.Test.Shipment

  setup do
    handler = "ash-metrics-increment-#{System.unique_integer([:positive])}"
    test_process = self()
    original = Application.get_env(:ash_metrics, :tag_extractor)

    :telemetry.attach_many(
      handler,
      [
        AshMetrics.event_name(Delivery, :delivery),
        AshMetrics.event_name(Invoice, :capture),
        AshMetrics.event_name(Shipment, :dispatch)
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

  describe "event_name/2" do
    test "namespaces the event by resource and metric" do
      assert AshMetrics.event_name(Delivery, :delivery) == [:ash_metrics, Delivery, :delivery]
    end
  end

  describe "increment/3" do
    test "emits the event name, a count of one, and the call-site tags" do
      assert AshMetrics.increment(Delivery, :delivery, tags: %{status: :sent}) == :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Delivery, :delivery]
      assert measurements == %{count: 1}
      assert metadata == %{status: :sent}
    end

    test "carries declared call-site tags" do
      AshMetrics.increment(Delivery, :delivery,
        tags: %{status: :bounced, provider: "ses", template: "welcome_v2"}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{status: :bounced, provider: "ses", template: "welcome_v2"}
    end

    test "accepts call-site tags as a keyword list" do
      AshMetrics.increment(Delivery, :delivery, tags: [status: :sent, provider: "ses"])

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{status: :sent, provider: "ses"}
    end

    test "raises when the tags are neither a map nor a keyword list" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Delivery, :delivery, tags: [:status])
        end

      assert error.message == "`tags:` takes a map or a keyword list, got: [:status]"
    end

    test "carries tags the extractor derives from metadata" do
      AshMetrics.increment(Delivery, :delivery,
        tags: %{status: :sent},
        metadata: %{tenant: "acme"}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{status: :sent, tenant: "acme"}
    end

    test "drops an unusable tenant rather than tagging with it" do
      AshMetrics.increment(Delivery, :delivery,
        tags: %{status: :sent},
        metadata: %{tenant: %URI{host: "acme.test"}}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{status: :sent}
    end

    test "call-site tags win over extracted ones" do
      Application.put_env(:ash_metrics, :tag_extractor, ProviderFromMetadata)

      AshMetrics.increment(Delivery, :delivery,
        tags: %{status: :sent, provider: "explicit"},
        metadata: %{provider: "extracted"}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{status: :sent, provider: "explicit"}
    end

    test "works for a counter that declares no tags" do
      assert AshMetrics.increment(Invoice, :capture) == :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Invoice, :capture]
      assert measurements == %{count: 1}
      assert metadata == %{}
    end

    test "raises when the metric is a distribution" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Delivery, :send_latency)
        end

      assert error.message ==
               ":send_latency on AshMetrics.Test.Delivery is a distribution, not a " <>
                 "counter. Use `observe/4` to record a distribution."
    end

    test "raises when the metric is a gauge" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Job, :backlog)
        end

      assert error.message ==
               ":backlog on AshMetrics.Test.Job is a gauge, not a counter. A gauge " <>
                 "is polled by AshMetrics itself and has no call site."
    end

    test "raises when the metric is not declared" do
      assert_raise ArgumentError, ~r/no metric :nope is declared/, fn ->
        AshMetrics.increment(Delivery, :nope)
      end
    end

    test "raises when the resource does not use the extension" do
      assert_raise ArgumentError, ~r/Declared metrics: none/, fn ->
        AshMetrics.increment(Plain, :delivery)
      end
    end

    test "raises when a tag is not declared, naming it and the declared tags" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Delivery, :delivery, tags: %{status: :sent, region: "eu"})
        end

      assert error.message ==
               ":region is not a declared tag of counter :delivery on " <>
                 "AshMetrics.Test.Delivery. Declared tags: :provider, :template, :status"
    end

    test "raises for any tag when the counter declares none" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Invoice, :capture, tags: %{provider: "ses"})
        end

      assert error.message =~ "Declared tags: none"
    end

    test "emits nothing when validation fails" do
      assert_raise ArgumentError, fn ->
        AshMetrics.increment(Delivery, :delivery, tags: %{status: :nope})
      end

      refute_received {:emitted, _event, _measurements, _metadata}
    end
  end

  describe "increment/3 with closed tags" do
    test "carries a closed tag and an open one" do
      assert AshMetrics.increment(Shipment, :dispatch, tags: %{status: :shipped, carrier: "ups"}) ==
               :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Shipment, :dispatch]
      assert measurements == %{count: 1}
      assert metadata == %{status: :shipped, carrier: "ups"}
    end

    test "leaves an open tag optional" do
      AshMetrics.increment(Shipment, :dispatch, tags: %{status: :queued})

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{status: :queued}
    end

    test "raises when a closed tag is missing, naming it and its declared values" do
      error = assert_raise ArgumentError, fn -> AshMetrics.increment(Shipment, :dispatch, []) end

      assert error.message ==
               ":status is a required tag of counter :dispatch on " <>
                 "AshMetrics.Test.Shipment. Declared values: :queued, :shipped, :lost"
    end

    test "raises when a closed tag's value is not declared" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Shipment, :dispatch, tags: %{status: :nope})
        end

      assert error.message ==
               ":nope is not a declared value of the tag :status of counter :dispatch " <>
                 "on AshMetrics.Test.Shipment. Declared values: :queued, :shipped, :lost"
    end
  end
end
