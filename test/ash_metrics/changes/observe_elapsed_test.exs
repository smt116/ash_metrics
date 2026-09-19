defmodule AshMetrics.Changes.ObserveElapsedTest do
  # Seeds an ETS table the whole node shares, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Ticket]

  alias Ash.BulkResult
  alias Ash.Error.Framework
  alias Ash.Error.Framework.MustBeAtomic
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Ticket

  @metric "test.queue.ticket.time_to_resolve"
  @counter "test.queue.ticket.transitions"

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    %{ticket: Ash.create!(Ticket, %{priority: :high, assignee: "ana"}, action: :open)}
  end

  test "observes the difference in the declared unit, tagged from the record", %{ticket: ticket} do
    resolve!(ticket, 1_500)

    assert {%{value: 1_500}, tags} = assert_metric_emitted(@metric)
    assert tags == %{priority: :high}
  end

  test "observes a negative difference as it is", %{ticket: ticket} do
    resolve!(ticket, -250)

    assert_metric_emitted(@metric, value: -250)
  end

  test "observes nothing when the change's where clause does not hold", %{ticket: ticket} do
    Ash.update!(
      ticket,
      %{status: :closed, resolved_at: DateTime.add(ticket.inserted_at, 1_500, :millisecond)},
      action: :update_status
    )

    refute_metric_emitted(@metric)
  end

  test "observes nothing when the later timestamp is nil", %{ticket: ticket} do
    Ash.update!(ticket, %{status: :resolved}, action: :update_status)

    refute_metric_emitted(@metric)
  end

  test "measures to now when no `to:` was given", %{ticket: ticket} do
    Ash.update!(ticket, %{}, action: :touch)

    assert {%{value: value}, _tags} = assert_metric_emitted(@metric)
    assert value >= 0
  end

  test "measures between a utc and a naive timestamp", %{ticket: ticket} do
    acknowledged_at =
      ticket.inserted_at
      |> DateTime.add(3, :second)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)

    Ash.update!(ticket, %{acknowledged_at: acknowledged_at}, action: :acknowledge)

    assert {%{value: value}, _tags} = assert_metric_emitted(@metric)
    assert_in_delta value, 3_000, 1_000
  end

  describe "an action that keeps require_atomic? true" do
    test "observes from a single update, alongside the counter", %{ticket: ticket} do
      Ash.update!(
        ticket,
        %{status: :resolved, resolved_at: DateTime.add(ticket.inserted_at, 900, :millisecond)},
        action: :resolve
      )

      assert_metric_emitted(@metric, value: 900, tags: %{priority: :high})
      assert_metric_emitted(@counter, tags: %{status: :resolved, assignee: "ana"})
    end

    test "observes once per record from Ash.bulk_update/4 under its default strategy",
         %{ticket: ticket} do
      Ash.create!(Ticket, %{priority: :low, assignee: "bo"}, action: :open)
      drain()

      assert %BulkResult{status: :success, records: records} =
               Ash.bulk_update(
                 Ticket,
                 :resolve,
                 %{
                   status: :resolved,
                   resolved_at: DateTime.add(ticket.inserted_at, 700, :millisecond)
                 },
                 return_records?: true
               )

      assert length(records) == 2

      assert_metric_emitted(@metric, tags: %{priority: :high})
      assert_metric_emitted(@metric, tags: %{priority: :low})
    end

    test "a where: reading an attribute leaves it unable to run", %{ticket: ticket} do
      assert {:error, %Framework{errors: [%MustBeAtomic{}]}} =
               Ash.update(
                 ticket,
                 %{
                   status: :resolved,
                   resolved_at: DateTime.add(ticket.inserted_at, 100, :millisecond)
                 },
                 action: :resolve_when_resolved
               )

      refute_metric_emitted(@metric)
    end
  end

  defp resolve!(ticket, milliseconds) do
    Ash.update!(
      ticket,
      %{
        status: :resolved,
        resolved_at: DateTime.add(ticket.inserted_at, milliseconds, :millisecond)
      },
      action: :update_status
    )
  end

  # Empties the mailbox of the emissions the seeding produced, so that only
  # what the action under test emitted is left to assert on.
  defp drain do
    receive do
      {:ash_metrics, _name, _measurements, _tags} -> drain()
    after
      0 -> :ok
    end
  end
end
