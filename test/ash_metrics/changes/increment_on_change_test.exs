defmodule AshMetrics.Changes.IncrementOnChangeTest do
  # Seeds an ETS table the whole node shares, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Ticket]

  import ExUnit.CaptureLog

  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Ticket

  @metric "test.queue.ticket.transitions"

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    :ok
  end

  test "a create emits the value it wrote, with the record's other tags" do
    open!(priority: :high, assignee: "ana")

    assert {%{count: 1}, tags} = assert_metric_emitted(@metric)
    assert tags == %{status: :open, priority: :high, assignee: "ana"}
  end

  test "an update to a new value emits it" do
    ticket = open!(priority: :low, assignee: "ana")

    Ash.update!(ticket, %{status: :resolved}, action: :update_status)

    assert_metric_emitted(@metric, tags: %{status: :resolved, priority: :low})
  end

  test "an update that leaves the attribute alone emits nothing" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    Ash.update!(ticket, %{assignee: "bo"}, action: :rename)

    refute_metric_emitted(@metric)
  end

  test "an update writing the same value again emits nothing" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    Ash.update!(ticket, %{status: :open}, action: :update_status)

    refute_metric_emitted(@metric)
  end

  test "a failed action emits nothing" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    assert {:error, _error} = Ash.update(ticket, %{status: :nope}, action: :update_status)

    refute_metric_emitted(@metric)
  end

  test "the tag extractor reads the changeset's context" do
    ticket = open!(priority: :low, assignee: "ana")

    ticket
    |> Ash.Changeset.for_update(:update_status, %{status: :in_progress},
      context: %{tenant: "acme"}
    )
    |> Ash.update!()

    assert_metric_emitted(@metric, tags: %{status: :in_progress, tenant: "acme"})
  end

  test "a rejected emission is logged and leaves the action's result alone" do
    log =
      capture_log(fn ->
        assert %Ticket{priority: nil} = open!(assignee: "ana")
      end)

    assert log =~ "AshMetrics did not emit :transitions on AshMetrics.Test.Ticket"
    assert log =~ "from action :open"
    assert log =~ ":priority is a required tag"

    refute_metric_emitted(@metric)
  end

  defp open!(attrs), do: Ash.create!(Ticket, Map.new(attrs), action: :open)
end
