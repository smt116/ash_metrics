defmodule AshMetrics.NameBuilderTest.Slashed do
  @moduledoc false
  # A house style that disagrees with the default on every count: a different
  # separator, no domain segment, and an upper case prefix.

  @behaviour AshMetrics.NameBuilder

  alias AshMetrics.Info

  @impl AshMetrics.NameBuilder
  def build(prefix, resource, metric) do
    "#{String.upcase(prefix)}/#{Info.name(resource)}/#{metric}"
  end
end

defmodule AshMetrics.NameBuilderTest do
  # Swaps the configured name builder, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.NameBuilder
  alias AshMetrics.NameBuilderTest.Slashed
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice

  setup do
    original = Application.get_env(:ash_metrics, :name_builder)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, :name_builder)
        builder -> Application.put_env(:ash_metrics, :name_builder, builder)
      end
    end)

    :ok
  end

  describe "AshMetrics.NameBuilder.Default" do
    test "joins prefix, domain short name, resource name and metric" do
      assert NameBuilder.Default.build("myapp", Delivery, :delivery) ==
               "myapp.mailings.templated_delivery.delivery"
    end

    test "uses the resource short name when the metrics block declares no name" do
      assert NameBuilder.Default.build("myapp", Invoice, :capture) ==
               "myapp.mailings.invoice.capture"
    end
  end

  describe "build/2" do
    test "uses the configured prefix and the default builder" do
      assert NameBuilder.build(Delivery, :delivery) == "test.mailings.templated_delivery.delivery"

      assert NameBuilder.build(Delivery, :send_latency) ==
               "test.mailings.templated_delivery.send_latency"

      assert NameBuilder.build(Invoice, :capture) == "test.mailings.invoice.capture"
    end

    test "dispatches to a configured builder" do
      Application.put_env(:ash_metrics, :name_builder, Slashed)

      assert NameBuilder.build(Delivery, :delivery) == "TEST/templated_delivery/delivery"
    end

    test "raises when no prefix is configured" do
      original = Application.get_env(:ash_metrics, :prefix)
      Application.delete_env(:ash_metrics, :prefix)
      on_exit(fn -> Application.put_env(:ash_metrics, :prefix, original) end)

      assert_raise ArgumentError, ~r/`prefix` must be set/, fn ->
        NameBuilder.build(Delivery, :delivery)
      end
    end
  end
end
