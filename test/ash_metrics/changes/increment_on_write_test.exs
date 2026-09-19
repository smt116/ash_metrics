defmodule AshMetrics.Changes.IncrementOnWriteTest do
  # Seeds an ETS table the whole node shares, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Ticket]

  import ExUnit.CaptureLog

  alias Ash.BulkResult
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Ticket

  @metric "test.queue.ticket.transitions"

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    :ok
  end

  test "a create emits the value it wrote, with the record's other tags" do
    submit!(priority: :high, assignee: "ana")

    assert {%{count: 1}, tags} = assert_metric_emitted(@metric)
    assert tags == %{status: :open, priority: :high, assignee: "ana"}
  end

  test "an update to a new value emits it" do
    ticket = submit!(priority: :low, assignee: "ana")

    Ash.update!(ticket, %{status: :resolved}, action: :write_status)

    assert_metric_emitted(@metric, tags: %{status: :resolved, priority: :low})
  end

  test "an update writing the same value again emits it again" do
    ticket = submit!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    Ash.update!(ticket, %{status: :open}, action: :write_status)

    assert_metric_emitted(@metric, tags: %{status: :open})
  end

  test "a value outside the counter's closed set emits nothing" do
    ticket = submit!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    Ash.update!(ticket, %{status: :archived}, action: :write_status)

    refute_metric_emitted(@metric)
  end

  test "a failed action emits nothing" do
    ticket = submit!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    assert {:error, _error} = Ash.update(ticket, %{status: :nope}, action: :write_status)

    refute_metric_emitted(@metric)
  end

  test "the tag extractor reads the changeset's context" do
    ticket = submit!(priority: :low, assignee: "ana")

    ticket
    |> Ash.Changeset.for_update(:write_status, %{status: :in_progress},
      context: %{tenant: "acme"}
    )
    |> Ash.update!()

    assert_metric_emitted(@metric, tags: %{status: :in_progress, tenant: "acme"})
  end

  test "a rejected emission is logged and leaves the action's result alone" do
    log =
      capture_log(fn ->
        assert %Ticket{priority: nil} = submit!(assignee: "ana")
      end)

    assert log =~ "AshMetrics did not emit :transitions on AshMetrics.Test.Ticket"
    assert log =~ "from action :submit"
    assert log =~ ":priority is a required tag"

    refute_metric_emitted(@metric)
  end

  describe "an action that keeps require_atomic? true" do
    test "emits from a single update" do
      ticket = submit!(priority: :high, assignee: "ana")
      drain()

      Ash.update!(ticket, %{status: :resolved}, action: :write_status)

      assert_metric_emitted(@metric,
        tags: %{status: :resolved, priority: :high, assignee: "ana"}
      )
    end

    test "emits once per record from Ash.bulk_update/4 under its default strategy" do
      Enum.each(~w(ana bo cy), &submit!(priority: :low, assignee: &1))
      drain()

      assert %BulkResult{status: :success, records: records} =
               Ash.bulk_update(Ticket, :write_status, %{status: :resolved}, return_records?: true)

      assert length(records) == 3

      Enum.each(~w(ana bo cy), fn assignee ->
        assert_metric_emitted(@metric,
          tags: %{status: :resolved, priority: :low, assignee: assignee}
        )
      end)
    end
  end

  defp submit!(attrs), do: Ash.create!(Ticket, Map.new(attrs), action: :submit)

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
