defmodule AshMetrics.Changes.TagPathsTest do
  @moduledoc """
  What the three action changes make of a tag declaring a `path:`, and what a
  call site makes of the same tag.
  """

  # Seeds an ETS table the whole node shares, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Order]

  import ExUnit.CaptureLog

  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Order

  @placements "test.queue.order.placements"
  @dispatches "test.queue.order.dispatches"
  @fulfillment_time "test.queue.order.fulfillment_time"

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    :ok
  end

  describe "increment_on_change/2" do
    test "reads a tag one segment into an embedded attribute" do
      place!(%{state: :tx})

      assert {%{count: 1}, tags} = assert_metric_emitted(@placements)
      assert tags == %{status: :placed, state: :tx}
    end

    test "reads a tag two segments in" do
      place!(%{state: :tx, shipping_address: %{state: :ca}})

      assert {%{count: 1}, tags} = assert_metric_emitted(@placements)
      assert tags == %{status: :placed, state: :tx, shipping_state: :ca}
    end

    test "leaves the tag off when a segment on the way is nil" do
      place!(%{state: :tx})

      assert {_measurements, tags} = assert_metric_emitted(@placements)
      refute Map.has_key?(tags, :shipping_state)
    end

    test "leaves the tag off when the last segment is nil" do
      place!(%{state: :tx, shipping_address: %{}})

      assert {_measurements, tags} = assert_metric_emitted(@placements)
      refute Map.has_key?(tags, :shipping_state)
    end

    test "leaves every path tag off when the embedded attribute is nil" do
      place!(nil)

      assert {_measurements, tags} = assert_metric_emitted(@placements)
      assert tags == %{status: :placed}
    end
  end

  describe "increment_on_write/2" do
    test "carries a closed path tag holding one of its declared values" do
      dispatch!(%{state: :ca})

      assert_metric_emitted(@dispatches, tags: %{status: :placed, state: :ca})
    end

    test "skips the emission when a closed path tag holds anything else" do
      log = capture_log(fn -> dispatch!(%{state: :ny}) end)

      assert log =~ "AshMetrics did not emit :dispatches on AshMetrics.Test.Order"
      assert log =~ ":ny is not a declared value of the tag :state"

      refute_metric_emitted(@dispatches)
    end
  end

  describe "observe_elapsed/2" do
    test "carries the path tags of the distribution" do
      order = place!(%{state: :ca})

      ship!(order, 1_500)

      assert {%{value: 1_500}, tags} = assert_metric_emitted(@fulfillment_time)
      assert tags == %{state: :ca}
    end
  end

  describe "increment/3" do
    test "takes the value of a path tag from the call site" do
      AshMetrics.increment(Order, :placements,
        tags: %{status: :shipped, state: :ny, shipping_state: :tx}
      )

      assert {%{count: 1}, tags} = assert_metric_emitted(@placements)
      assert tags == %{status: :shipped, state: :ny, shipping_state: :tx}
    end
  end

  defp place!(location) do
    Ash.create!(Order, %{status: :placed, location: location}, action: :place)
  end

  defp dispatch!(location) do
    Ash.create!(Order, %{status: :placed, location: location}, action: :dispatch)
  end

  defp ship!(order, milliseconds) do
    Ash.update!(
      order,
      %{status: :shipped, shipped_at: DateTime.add(order.placed_at, milliseconds, :millisecond)},
      action: :ship
    )
  end
end
