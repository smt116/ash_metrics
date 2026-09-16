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
  alias AshMetrics.Test.Plain

  setup do
    handler = "ash-metrics-increment-#{System.unique_integer([:positive])}"
    test_process = self()
    original = Application.get_env(:ash_metrics, :tag_extractor)

    :telemetry.attach_many(
      handler,
      [
        AshMetrics.event_name(Delivery, :delivery),
        AshMetrics.event_name(Invoice, :capture)
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
    test "emits the event name, a count of one, and the outcome tag" do
      assert AshMetrics.increment(Delivery, :delivery, outcome: :sent) == :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Delivery, :delivery]
      assert measurements == %{count: 1}
      assert metadata == %{outcome: :sent}
    end

    test "carries declared call-site tags" do
      AshMetrics.increment(Delivery, :delivery,
        outcome: :bounced,
        tags: %{provider: "ses", template: "welcome_v2"}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{outcome: :bounced, provider: "ses", template: "welcome_v2"}
    end

    test "carries tags the extractor derives from metadata" do
      AshMetrics.increment(Delivery, :delivery, outcome: :sent, metadata: %{tenant: "acme"})

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{outcome: :sent, tenant: "acme"}
    end

    test "drops an unusable tenant rather than tagging with it" do
      AshMetrics.increment(Delivery, :delivery,
        outcome: :sent,
        metadata: %{tenant: %URI{host: "acme.test"}}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{outcome: :sent}
    end

    test "call-site tags win over extracted ones" do
      Application.put_env(:ash_metrics, :tag_extractor, ProviderFromMetadata)

      AshMetrics.increment(Delivery, :delivery,
        outcome: :sent,
        tags: %{provider: "explicit"},
        metadata: %{provider: "extracted"}
      )

      assert_received {:emitted, _event, _measurements, metadata}

      assert metadata == %{outcome: :sent, provider: "explicit"}
    end

    test "works for a counter that declares no tags" do
      assert AshMetrics.increment(Invoice, :capture, outcome: :succeeded) == :ok

      assert_received {:emitted, event, measurements, metadata}
      assert event == [:ash_metrics, AshMetrics.Test.Invoice, :capture]
      assert measurements == %{count: 1}
      assert metadata == %{outcome: :succeeded}
    end

    test "raises when the metric is a distribution" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Delivery, :send_latency, outcome: :sent)
        end

      assert error.message ==
               ":send_latency on AshMetrics.Test.Delivery is a distribution, not a " <>
                 "counter. Use observe/4 to record a distribution."
    end

    test "raises when the metric is not declared" do
      assert_raise ArgumentError, ~r/no metric :nope is declared/, fn ->
        AshMetrics.increment(Delivery, :nope, outcome: :sent)
      end
    end

    test "raises when the resource does not use the extension" do
      assert_raise ArgumentError, ~r/Declared metrics: none/, fn ->
        AshMetrics.increment(Plain, :delivery, outcome: :sent)
      end
    end

    test "raises when no outcome is given, listing the declared outcomes" do
      error = assert_raise ArgumentError, fn -> AshMetrics.increment(Invoice, :capture, []) end

      assert error.message ==
               "increment/3 requires an `outcome:` option. Counter :capture on " <>
                 "AshMetrics.Test.Invoice declares the outcomes: :succeeded, :failed"
    end

    test "raises when the outcome is not declared, listing the declared outcomes" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Invoice, :capture, outcome: :sent)
        end

      assert error.message ==
               ":sent is not a declared outcome of counter :capture on " <>
                 "AshMetrics.Test.Invoice. Declared outcomes: :succeeded, :failed"
    end

    test "raises when a tag is not declared, naming it and the declared tags" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Delivery, :delivery, outcome: :sent, tags: %{region: "eu"})
        end

      assert error.message ==
               ":region is not a declared tag of counter :delivery on " <>
                 "AshMetrics.Test.Delivery. Declared tags: :provider, :template"
    end

    test "raises for any tag when the counter declares none" do
      error =
        assert_raise ArgumentError, fn ->
          AshMetrics.increment(Invoice, :capture, outcome: :failed, tags: %{provider: "ses"})
        end

      assert error.message =~ "Declared tags: none"
    end

    test "emits nothing when validation fails" do
      assert_raise ArgumentError, fn ->
        AshMetrics.increment(Delivery, :delivery, outcome: :nope)
      end

      refute_received {:emitted, _event, _measurements, _metadata}
    end
  end
end
