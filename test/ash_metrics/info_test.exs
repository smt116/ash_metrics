defmodule AshMetrics.InfoTest do
  use ExUnit.Case, async: true

  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Info
  alias AshMetrics.Test.Delivery
  alias AshMetrics.Test.Invoice
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.MarkedJob
  alias AshMetrics.Test.MarkerPoller
  alias AshMetrics.Test.Plain
  alias AshMetrics.Test.Shipment
  alias AshMetrics.Test.Ticket

  describe "metrics/1" do
    test "returns the declarations of a resource in declaration order" do
      assert [%Counter{} = counter, %Distribution{} = distribution] = Info.metrics(Delivery)

      assert counter.name == :delivery
      assert counter.tags == [:provider, :template, :status]
      assert counter.tag_values == %{status: [:queued, :sent, :bounced, :delivered, :error]}
      assert counter.description == "Templated deliveries by status"

      assert distribution.name == :send_latency
      assert distribution.unit == {:native, :millisecond}
      assert distribution.buckets == [10, 50, 100, 250, 500]
      assert distribution.tags == [:provider]
      assert distribution.tag_values == %{}
      assert distribution.description == "Time from enqueue to provider acknowledgement"
    end

    test "normalizes a closed tag declared in keyword syntax" do
      assert %Counter{} = counter = Info.metric!(Shipment, :dispatch)

      assert counter.tags == [:carrier, :status]
      assert counter.tag_values == %{status: [:queued, :shipped, :lost]}
    end

    test "normalizes a closed tag declared as a tuple, wherever it appears" do
      assert %Distribution{} = distribution = Info.metric!(Shipment, :transit_time)

      assert distribution.tags == [:carrier, :region]
      assert distribution.tag_values == %{carrier: [:ups, :dhl]}
    end

    test "defaults tags to an empty list and description to nil" do
      assert [
               %Counter{name: :capture, tags: [], tag_values: %{}, description: nil},
               %Distribution{
                 name: :settlement_lag,
                 unit: :unit,
                 buckets: nil,
                 tags: [],
                 tag_values: %{},
                 description: nil
               }
             ] = Info.metrics(Invoice)
    end

    test "derives a distribution's suffix from its unit" do
      assert %Distribution{suffix: :duration} = Info.metric!(Delivery, :send_latency)
      assert %Distribution{suffix: :duration} = Info.metric!(Ticket, :time_to_resolve)
      assert %Distribution{suffix: :bytes} = Info.metric!(Shipment, :label_size)
      assert %Distribution{suffix: :value} = Info.metric!(Invoice, :settlement_lag)
    end

    test "keeps the suffix a distribution declares" do
      assert %Distribution{suffix: :latency} = Info.metric!(Shipment, :handling_delay)
    end

    test "returns an empty list for a resource without the extension" do
      assert Info.metrics(Plain) == []
    end

    test "returns the gauges of a resource" do
      assert [%Gauge{} = backlog, %Gauge{} = total] = Info.metrics(Job)

      assert backlog.name == :backlog
      assert backlog.group_by == [:status, :provider]
      assert backlog.strategy == :count
      assert backlog.period == 60_000
      assert backlog.description == "Jobs waiting to be picked up"

      assert total.name == :total
      assert total.period == 30_000
    end

    test "keeps a gauge's filter as the Ash expression it was declared as" do
      assert %Gauge{filter: filter} = Info.metric!(Job, :backlog)

      assert is_struct(filter)
      assert inspect(filter) == "status in [:pending, :processing]"
    end

    test "defaults a gauge's filter, grouping, strategy and period" do
      assert %Gauge{
               name: :total,
               filter: nil,
               group_by: [],
               strategy: :count,
               description: nil
             } = Info.metric!(Job, :total)
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

  describe "poller/1" do
    test "falls back to the configured poller" do
      assert Info.poller(Job) == AshMetrics.Poller.GenServer
    end

    test "uses the declared poller when the metrics section sets one" do
      assert Info.poller(MarkedJob) == MarkerPoller
    end

    test "falls back to the configured poller for a resource with no metrics" do
      assert Info.poller(Plain) == AshMetrics.Poller.GenServer
    end
  end
end
