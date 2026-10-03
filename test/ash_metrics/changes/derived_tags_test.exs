defmodule AshMetrics.Changes.DerivedTagsTest do
  @moduledoc """
  What the three action changes make of a tag naming a calculation or an
  aggregate of the resource.
  """

  # Seeds an ETS table the whole node shares, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Parcel]

  import ExUnit.CaptureLog

  alias Ash.BulkResult
  alias AshMetrics.Changes.Emission
  alias AshMetrics.Changes.TagLoadError
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Parcel
  alias AshMetrics.Test.ParcelScan

  @receptions "test.queue.parcel.receptions"
  @audits "test.queue.parcel.audits"
  @transit_time "test.queue.parcel.transit_time"

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    :ok
  end

  describe "increment_on_change/2" do
    test "reads calculations and aggregates of the written record" do
      receive!(5)

      assert {%{count: 1}, tags} = assert_metric_emitted(@receptions)

      assert tags == %{
               status: :received,
               size: :small,
               weight_class: :light,
               hidden_size: :small,
               scan_count: 0,
               scanned: false
             }
    end

    test "reads a path into a calculation returning an embedded resource" do
      Ash.create!(Parcel, %{weight: 5, destination: %{state: :ca}}, action: :receive)

      assert_metric_emitted(@receptions, tags: %{route_state: :ca})
    end

    test "leaves a path tag off when the calculation returns nil" do
      receive!(5)

      assert {_measurements, tags} = assert_metric_emitted(@receptions)
      refute Map.has_key?(tags, :route_state)
    end

    test "computes a calculation from the values the action wrote" do
      receive!(50)

      assert_metric_emitted(@receptions,
        tags: %{size: :large, weight_class: :heavy, hidden_size: :large}
      )
    end

    test "leaves the record the action returns without the loaded values" do
      parcel = receive!(5)

      assert %Ash.NotLoaded{} = parcel.size
      assert %Ash.NotLoaded{} = parcel.scan_count
      assert parcel.calculations == %{}
    end
  end

  describe "increment_on_write/2" do
    test "reads aggregates over the related rows as they are when it emits" do
      parcel = receive!(5)
      drain()

      Ash.create!(ParcelScan, %{parcel_id: parcel.id})
      Ash.create!(ParcelScan, %{parcel_id: parcel.id})

      Ash.update!(parcel, %{status: :delivered, weight: 50}, action: :deliver)

      assert_metric_emitted(@receptions,
        tags: %{status: :delivered, size: :large, scanned: true, scan_count: 2}
      )
    end

    test "reads fresh values over stale ones the record already holds" do
      parcel = receive!(5)
      loaded = Ash.load!(parcel, [:size, :hidden_size, :scan_count, :scanned])
      assert %Parcel{size: :small, scan_count: 0, scanned: false} = loaded

      Ash.create!(ParcelScan, %{parcel_id: parcel.id})
      Ash.update!(parcel, %{status: :delivered, weight: 50}, action: :deliver)
      stale = %{loaded | status: :delivered, weight: 50}

      changeset = Ash.Changeset.for_update(stale, :deliver, %{})
      counter = AshMetrics.Info.metric!(Parcel, :receptions)

      assert %{size: :large, hidden_size: :large, scan_count: 1, scanned: true} =
               Emission.record_tags(changeset, stale, counter)
    end

    test "raises an Ash error a load throws as the data layer's rollback" do
      parcel = receive!(5)
      changeset = Ash.Changeset.for_update(parcel, :deliver, %{})
      counter = AshMetrics.Info.metric!(Parcel, :rollbacks)

      error =
        assert_raise TagLoadError, fn -> Emission.record_tags(changeset, parcel, counter) end

      assert %TagLoadError{fields: [:rolled_back], error: %Ash.Error.Unknown{} = class} = error
      assert Exception.message(class) =~ "the data layer rolled back"
    end

    test "loads the values once for each record of a bulk create" do
      assert %BulkResult{status: :success} =
               Ash.bulk_create([%{weight: 5}, %{weight: 50}], Parcel, :receive)

      assert_metric_emitted(@receptions, tags: %{size: :small})
      assert_metric_emitted(@receptions, tags: %{size: :large})
      refute_metric_emitted(@receptions)
    end

    test "logs a calculation that fails to load outside a transaction and emits nothing" do
      log =
        capture_log(fn ->
          assert %Parcel{status: :received} = Ash.create!(Parcel, %{weight: 5}, action: :audit)
        end)

      assert log =~ "AshMetrics did not emit :audits on AshMetrics.Test.Parcel"
      assert log =~ "could not load [:faulty]"
      assert log =~ "the calculation failed"

      refute_metric_emitted(@audits)
    end
  end

  describe "observe_elapsed/2" do
    test "carries the calculations and aggregates the distribution declares" do
      parcel = receive!(50)
      Ash.create!(ParcelScan, %{parcel_id: parcel.id})

      Ash.update!(
        parcel,
        %{status: :delivered, delivered_at: DateTime.add(parcel.received_at, 750, :millisecond)},
        action: :deliver
      )

      assert {%{value: 750}, tags} = assert_metric_emitted(@transit_time)
      assert tags == %{size: :large, scanned: true}
    end
  end

  defp receive!(weight) do
    Ash.create!(Parcel, %{weight: weight}, action: :receive)
  end

  # Empties the mailbox of the emissions the seeding produced.
  defp drain do
    receive do
      {:ash_metrics, _name, _measurements, _tags} -> drain()
    after
      0 -> :ok
    end
  end
end
