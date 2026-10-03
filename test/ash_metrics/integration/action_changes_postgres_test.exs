defmodule AshMetrics.Integration.ActionChangesPostgresTest do
  # Seeds a shared table in a real database, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.PgTicket]

  import ExUnit.CaptureLog

  @moduletag :postgres

  alias Ash.BulkResult
  alias Ash.Error.Invalid.NoMatchingBulkStrategy
  alias AshMetrics.Changes.Emission
  alias AshMetrics.Changes.TagLoadError
  alias AshMetrics.Test.PgTicket
  alias AshMetrics.Test.PgTicketComment
  alias AshMetrics.Test.Repo

  @transitions "test.pg.pg_ticket.transitions"
  @elapsed "test.pg.pg_ticket.time_to_resolve"
  @escalations "test.pg.pg_ticket.escalations"
  @audits "test.pg.pg_ticket.audits"
  @reviews "test.pg.pg_ticket.reviews"

  setup do
    empty!()
    on_exit(&empty!/0)

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

  describe "a tag read from an aggregate" do
    test "counts the related rows" do
      ticket = open!("ana")
      comment!(ticket)
      comment!(ticket)

      Ash.update!(ticket, %{status: :in_progress}, action: :escalate)

      assert_metric_emitted(@escalations,
        tags: %{status: :in_progress, commented: true, comment_count: 2}
      )
    end

    test "sees the uncommitted rows of a surrounding transaction" do
      ticket = open!("ana")

      assert {:ok, _ticket} =
               Ash.transaction([PgTicket, PgTicketComment], fn ->
                 comment!(ticket)
                 Ash.update!(ticket, %{status: :in_progress}, action: :escalate)
               end)

      assert_metric_emitted(@escalations, tags: %{commented: true, comment_count: 1})
    end

    test "is read for each record of a bulk update" do
      ana = open!("ana")
      open!("bo")
      comment!(ana)

      assert %BulkResult{status: :success} =
               Ash.bulk_update(PgTicket, :escalate, %{status: :in_progress})

      assert_metric_emitted(@escalations, tags: %{commented: true, comment_count: 1})
      assert_metric_emitted(@escalations, tags: %{commented: false, comment_count: 0})
      refute_metric_emitted(@escalations)
    end
  end

  describe "a tag read from an expression calculation" do
    test "is computed from the written row and its related rows" do
      busy = open!("ana")
      quiet = open!("bo")
      comment!(busy)
      comment!(busy)
      comment!(quiet)

      Ash.update!(busy, %{status: :in_progress}, action: :escalate)
      assert_metric_emitted(@escalations, tags: %{discussion: :busy, comment_count: 2})

      Ash.update!(quiet, %{status: :in_progress}, action: :escalate)
      assert_metric_emitted(@escalations, tags: %{discussion: :quiet})
    end
  end

  describe "a tag whose calculation fails to load inside a surrounding transaction" do
    test "rolls the transaction back with the error when Postgres rejects the calculation" do
      ticket = open!("ana")
      drain()

      assert {:error, %Ash.Error.Unknown{errors: [%TagLoadError{} = error]}} =
               fail_in_transaction(ticket, :audit)

      assert %TagLoadError{resource: PgTicket, action: :audit, metric: :audits} = error
      assert error.fields == [:broken]
      assert %Ash.Error.Unknown{} = error.error

      message = Exception.message(error)
      assert message =~ "division by zero"
      refute message =~ "#Ash.Query<"

      refute_received :statement_after_the_action
      assert [%PgTicket{status: :open}] = Ash.read!(PgTicket)
      refute_metric_emitted(@audits)
    end

    test "rolls the transaction back with the error when the calculation raises" do
      ticket = open!("ana")
      drain()

      assert {:error, %Ash.Error.Unknown{errors: [%TagLoadError{} = error]}} =
               fail_in_transaction(ticket, :review)

      assert %TagLoadError{action: :review, metric: :reviews, fields: [:faulty]} = error
      assert Exception.message(error) =~ "the calculation failed"

      refute_received :statement_after_the_action
      assert [%PgTicket{status: :open}] = Ash.read!(PgTicket)
      refute_metric_emitted(@reviews)
    end

    test "rolls the transaction back when the changeset was built outside it" do
      ticket = open!("ana")
      drain()
      changeset = Ash.Changeset.for_update(ticket, :review, %{status: :in_progress})
      test = self()

      capture_log(fn ->
        assert {:error, %Ash.Error.Unknown{errors: [%TagLoadError{metric: :reviews}]}} =
                 Ash.transaction(PgTicket, fn ->
                   open!("bo")
                   Ash.update(changeset)
                   send(test, :statement_after_the_action)
                   Ash.read!(PgTicket)
                 end)
      end)

      refute_received :statement_after_the_action
      assert [%PgTicket{status: :open}] = Ash.read!(PgTicket)
      refute_metric_emitted(@reviews)
    end

    test "rolls the transaction back from a bulk update, whatever its strategy" do
      Enum.each(~w(ana bo), &open!/1)
      drain()

      for strategy <- [:atomic, :stream] do
        assert {:error, %Ash.Error.Unknown{errors: [%TagLoadError{}]}} =
                 Ash.transaction(PgTicket, fn ->
                   Ash.bulk_update(PgTicket, :audit, %{status: :in_progress},
                     strategy: strategy,
                     rollback_on_error?: false
                   )
                 end)
      end

      assert Enum.map(Ash.read!(PgTicket), & &1.status) == [:open, :open]
      refute_metric_emitted(@audits)
    end
  end

  describe "a tag whose calculation fails to load outside a transaction" do
    test "is logged, and the write persists" do
      ticket = open!("ana")

      log =
        capture_log(fn ->
          assert {:ok, %PgTicket{status: :in_progress}} =
                   Ash.update(ticket, %{status: :in_progress}, action: :audit)
        end)

      assert log =~ "AshMetrics did not emit :audits on AshMetrics.Test.PgTicket"
      assert log =~ "division by zero"

      assert Ash.get!(PgTicket, ticket.id).status == :in_progress
      refute_metric_emitted(@audits)
    end

    test "is logged from a bulk update, and the writes persist" do
      Enum.each(~w(ana bo), &open!/1)

      log =
        capture_log(fn ->
          assert %BulkResult{status: :success} =
                   Ash.bulk_update(PgTicket, :audit, %{status: :in_progress})
        end)

      assert log =~ "AshMetrics did not emit :audits"
      assert Enum.map(Ash.read!(PgTicket), & &1.status) == [:in_progress, :in_progress]
      refute_metric_emitted(@audits)
    end

    test "is logged from a streamed bulk update, and the writes persist" do
      Enum.each(~w(ana bo), &open!/1)

      log =
        capture_log(fn ->
          assert %BulkResult{status: :success} =
                   Ash.bulk_update(PgTicket, :audit, %{status: :in_progress}, strategy: :stream)
        end)

      assert log =~ "AshMetrics did not emit :audits"
      assert log =~ "division by zero"
      assert Enum.map(Ash.read!(PgTicket), & &1.status) == [:in_progress, :in_progress]
      refute_metric_emitted(@audits)
    end
  end

  describe "a destroy" do
    test "emits the value the destroyed row held, with its attribute tags" do
      ticket = open!("ana")
      drain()

      assert :ok = Ash.destroy(ticket, action: :discard)

      assert {%{count: 1}, tags} = assert_metric_emitted(@transitions)
      assert tags == %{status: :open, priority: :low, assignee: "ana"}
      assert [] = Ash.read!(PgTicket)
    end

    test "leaves off the tags read from aggregates and calculations over related rows" do
      ticket = open!("ana")
      changeset = Ash.Changeset.for_destroy(ticket, :destroy)
      destroyed = Ash.destroy!(changeset, return_destroyed?: true)

      tags =
        Emission.record_tags(
          changeset,
          destroyed,
          AshMetrics.Info.metric!(PgTicket, :escalations)
        )

      assert tags == %{status: :open}
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

  defp empty! do
    Repo.delete_all(PgTicketComment)
    Repo.delete_all(PgTicket)
  end

  defp comment!(ticket) do
    Ash.create!(PgTicketComment, %{ticket_id: ticket.id})
  end

  # Opens a ticket, runs `action` on `ticket` and reads the table, all in one
  # transaction, reporting whether the statement after the action ran.
  defp fail_in_transaction(ticket, action) do
    test = self()

    Ash.transaction(PgTicket, fn ->
      open!("bo")
      Ash.update(ticket, %{status: :in_progress}, action: action)
      send(test, :statement_after_the_action)
      Ash.read!(PgTicket)
    end)
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
