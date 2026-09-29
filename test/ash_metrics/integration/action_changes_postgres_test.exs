defmodule AshMetrics.Integration.ActionChangesPostgresTest do
  # Seeds a shared table in a real database, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.PgTicket]

  import ExUnit.CaptureLog

  @moduletag :postgres

  alias Ash.BulkResult
  alias Ash.Error.Invalid.NoMatchingBulkStrategy
  alias AshMetrics.Test.PgTicket
  alias AshMetrics.Test.Repo

  @transitions "test.pg.pg_ticket.transitions"
  @elapsed "test.pg.pg_ticket.time_to_resolve"

  setup do
    Repo.delete_all(PgTicket)
    on_exit(fn -> Repo.delete_all(PgTicket) end)

    :ok
  end

  describe "a single action" do
    test "emits the transition and the elapsed time" do
      ticket = open!("ana")

      Ash.update!(
        ticket,
        %{status: :resolved, resolved_at: DateTime.add(ticket.inserted_at, 2_000, :millisecond)},
        action: :update_status
      )

      assert_metric_emitted(@transitions, tags: %{status: :resolved, assignee: "ana"})
      assert_metric_emitted(@elapsed, value: 2_000, tags: %{priority: :low})
    end

    test "emits both from an action that keeps require_atomic? true" do
      ticket = open!("ana")

      Ash.update!(
        ticket,
        %{status: :resolved, resolved_at: DateTime.add(ticket.inserted_at, 1_000, :millisecond)},
        action: :resolve
      )

      assert_metric_emitted(@transitions, tags: %{status: :resolved, assignee: "ana"})
      assert_metric_emitted(@elapsed, value: 1_000, tags: %{priority: :low})
    end
  end

  describe "an action outside a transaction" do
    test "emits each metric once and logs no transaction hook warning" do
      log =
        capture_log(fn ->
          ticket = open!("bo")
          update_status!(ticket, 2_000)
          resolve!(ticket, 3_000)
        end)

      refute log =~ "after_transaction"
      assert_emitted_once()
    end
  end

  describe "an action inside a surrounding transaction" do
    test "emits each metric once and logs no transaction hook warning" do
      ticket = open!("ana")
      drain()

      log =
        capture_log(fn ->
          assert {:ok, _ticket} =
                   Ash.transaction(PgTicket, fn ->
                     open!("bo")
                     update_status!(ticket, 2_000)
                     resolve!(ticket, 3_000)
                   end)
        end)

      refute log =~ "after_transaction"
      assert_emitted_once()
    end

    test "emits even when the surrounding transaction rolls back" do
      ticket = open!("ana")
      drain()

      assert {:error, _rolled_back} =
               Ash.transaction(PgTicket, fn ->
                 open!("bo")
                 update_status!(ticket, 2_000)
                 resolve!(ticket, 3_000)
                 Ash.DataLayer.rollback(PgTicket, :rolled_back)
               end)

      assert Ash.get!(PgTicket, ticket.id).status == :open
      assert_emitted_once()
    end
  end

  describe "an action that fails in a later after_action hook" do
    test "emits nothing outside a transaction" do
      ticket = open!("ana")
      drain()

      assert {:error, _error} =
               Ash.update(ticket, %{status: :resolved}, action: :update_status_then_fail)

      assert Ash.get!(PgTicket, ticket.id).status == :open
      refute_metric_emitted(@transitions)
    end

    test "still emits inside a surrounding transaction" do
      ticket = open!("ana")
      drain()

      assert {:error, _error} =
               Ash.transaction(PgTicket, fn ->
                 Ash.update(ticket, %{status: :resolved}, action: :update_status_then_fail)
               end)

      assert Ash.get!(PgTicket, ticket.id).status == :open
      assert_metric_emitted(@transitions, tags: %{status: :resolved})
      refute_metric_emitted(@transitions)
    end
  end

  describe "Ash.bulk_update/4" do
    test "emits once per record under the :stream strategy" do
      Enum.each(~w(ana bo cy), &open!/1)
      drain()

      assert %BulkResult{status: :success, records: records} =
               Ash.bulk_update(PgTicket, :update_status, %{status: :resolved},
                 strategy: :stream,
                 return_records?: true
               )

      assert length(records) == 3

      Enum.each(~w(ana bo cy), fn assignee ->
        assert_metric_emitted(@transitions,
          tags: %{status: :resolved, priority: :low, assignee: assignee}
        )
      end)
    end

    test "refuses the default :atomic strategy, naming the change" do
      Enum.each(~w(ana bo), &open!/1)
      drain()

      assert %BulkResult{status: :error, errors: [error]} =
               Ash.bulk_update(PgTicket, :update_status, %{status: :resolved},
                 return_errors?: true
               )

      assert [%NoMatchingBulkStrategy{} = strategy] = error.errors
      assert strategy.requested_strategies == [:atomic]
      assert strategy.not_atomic_reason =~ "AshMetrics.Changes.IncrementOnChange"
      assert strategy.not_atomic_reason =~ "strategy: :stream"

      refute_metric_emitted(@transitions)
    end

    test "emits once per record under the default :atomic strategy" do
      Enum.each(~w(ana bo), &open!/1)
      drain()

      assert %BulkResult{status: :success, records: records} =
               Ash.bulk_update(PgTicket, :resolve, %{status: :resolved}, return_records?: true)

      assert length(records) == 2

      Enum.each(~w(ana bo), fn assignee ->
        assert_metric_emitted(@transitions,
          tags: %{status: :resolved, priority: :low, assignee: assignee}
        )
      end)
    end

    test "falls back to streaming when :stream is among the strategies" do
      ticket = open!("ana")
      drain()

      assert %BulkResult{status: :success} =
               Ash.bulk_update(
                 PgTicket,
                 :update_status,
                 %{
                   status: :resolved,
                   resolved_at: DateTime.add(ticket.inserted_at, 500, :millisecond)
                 },
                 strategy: [:atomic, :stream],
                 return_records?: true
               )

      assert_metric_emitted(@transitions, tags: %{status: :resolved, assignee: "ana"})
      assert_metric_emitted(@elapsed, value: 500)
    end
  end

  describe "Ash.bulk_create/4" do
    test "emits once per record" do
      assert %BulkResult{status: :success, records: records} =
               Ash.bulk_create(
                 [
                   %{priority: :low, assignee: "ana"},
                   %{priority: :high, assignee: "bo"}
                 ],
                 PgTicket,
                 :open,
                 return_records?: true
               )

      assert length(records) == 2

      assert_metric_emitted(@transitions,
        tags: %{status: :open, priority: :low, assignee: "ana"}
      )

      assert_metric_emitted(@transitions,
        tags: %{status: :open, priority: :high, assignee: "bo"}
      )
    end
  end

  defp open!(assignee) do
    Ash.create!(PgTicket, %{priority: :low, assignee: assignee}, action: :open)
  end

  # `:update_status` runs `IncrementOnChange` and `ObserveElapsed`.
  defp update_status!(ticket, elapsed) do
    Ash.update!(
      ticket,
      %{status: :resolved, resolved_at: DateTime.add(ticket.inserted_at, elapsed, :millisecond)},
      action: :update_status
    )
  end

  # `:resolve` runs `IncrementOnWrite` and `ObserveElapsed`.
  defp resolve!(ticket, elapsed) do
    Ash.update!(
      ticket,
      %{status: :resolved, resolved_at: DateTime.add(ticket.inserted_at, elapsed, :millisecond)},
      action: :resolve
    )
  end

  # What `open!/1`, `update_status!/2` and `resolve!/2` emit, each exactly once.
  defp assert_emitted_once do
    assert_metric_emitted(@transitions, tags: %{status: :open})
    assert_metric_emitted(@transitions, tags: %{status: :resolved})
    assert_metric_emitted(@transitions, tags: %{status: :resolved})
    refute_metric_emitted(@transitions)
    assert_metric_emitted(@elapsed, value: 2_000)
    assert_metric_emitted(@elapsed, value: 3_000)
    refute_metric_emitted(@elapsed)
  end

  # Empties the mailbox of the emissions the seeding produced, so that only
  # what the bulk action emitted is left to assert on.
  defp drain do
    receive do
      {:ash_metrics, _name, _measurements, _tags} -> drain()
    after
      0 -> :ok
    end
  end
end
