defmodule AshMetrics.InfoTest do
  use ExUnit.Case, async: true

  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Info
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Plain

  describe "metrics/1" do
    test "returns the declarations of a resource in declaration order" do
      assert [%Counter{} = counter, %Distribution{} = distribution] = Info.metrics(Delivery)

      assert counter.name == :delivery
      assert counter.outcomes == [:queued, :sent, :bounced, :delivered, :error]
      assert counter.tags == [:provider, :template]
      assert counter.description == "Templated deliveries by outcome"

      assert distribution.name == :send_latency
      assert distribution.unit == {:native, :millisecond}
      assert distribution.buckets == [10, 50, 100, 250, 500]
      assert distribution.tags == [:provider]
      assert distribution.description == "Time from enqueue to provider acknowledgement"
    end

    test "defaults tags to an empty list and description to nil" do
      assert [
               %Counter{name: :capture, tags: [], description: nil},
               %Distribution{
                 name: :settlement_lag,
                 unit: :unit,
                 buckets: nil,
                 tags: [],
                 description: nil
               }
             ] = Info.metrics(Invoice)
    end

    test "returns an empty list for a resource without the extension" do
      assert Info.metrics(Plain) == []
    end
  end

  describe "metric/2" do
    test "fetches a declaration by name" do
      assert {:ok, %Counter{name: :delivery}} = Info.metric(Delivery, :delivery)
      assert {:ok, %Distribution{name: :send_latency}} = Info.metric(Delivery, :send_latency)
    end

    test "returns :error for an unknown name" do
      assert Info.metric(Delivery, :nope) == :error
    end
  end

  describe "metric!/2" do
    test "fetches a declaration by name" do
      assert %Counter{name: :capture} = Info.metric!(Invoice, :capture)
    end

    test "raises listing the declared metrics" do
      error = assert_raise ArgumentError, fn -> Info.metric!(Delivery, :nope) end

      assert error.message ==
               "no metric :nope is declared on AshMetrics.Test.Delivery. " <>
                 "Declared metrics: :delivery, :send_latency"
    end

    test "raises saying none are declared when the resource has no metrics" do
      error = assert_raise ArgumentError, fn -> Info.metric!(Plain, :nope) end

      assert error.message =~ "Declared metrics: none"
    end
  end

  describe "name/1" do
    test "uses the declared name when the metrics section sets one" do
      assert Info.name(Delivery) == :templated_delivery
    end

    test "falls back to the resource short name" do
      assert Info.name(Invoice) == :invoice
    end
  end
end
