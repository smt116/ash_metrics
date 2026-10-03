defmodule AshMetrics.Test.PgTicket do
  @moduledoc false
  # `AshMetrics.Test.Ticket` again, on Postgres instead of ETS, so that the
  # action changes can be exercised against a data layer that runs bulk
  # updates and bulk creates for real, plus aggregates over
  # `AshMetrics.Test.PgTicketComment` and an expression calculation over them
  # that a counter tags with, and two calculations that fail to load, one in
  # Postgres and one in Elixir, each tagging a counter of its own.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshMetrics]

  metrics do
    counter :transitions,
      tags: [
        :assignee,
        priority: [:low, :high],
        status: [:open, :in_progress, :resolved, :closed]
      ],
      description: "Ticket status transitions"

    distribution :time_to_resolve,
      unit: :millisecond,
      tags: [priority: [:low, :high]],
      description: "Time from opening a ticket to resolving it"

    counter :escalations,
      tags: [
        :commented,
        :comment_count,
        :discussion,
        status: [:open, :in_progress, :resolved, :closed]
      ],
      description: "Ticket escalations by whether the ticket was discussed"

    counter :audits,
      tags: [:broken, status: [:open, :in_progress, :resolved, :closed]],
      description: "Ticket audits"

    counter :reviews,
      tags: [:faulty, status: [:open, :in_progress, :resolved, :closed]],
      description: "Ticket reviews"
  end

  postgres do
    table "pg_tickets"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:open, :in_progress, :resolved, :closed]]

    attribute :priority, :atom, public?: true, constraints: [one_of: [:low, :high]]
    attribute :assignee, :string, public?: true

    create_timestamp :inserted_at

    attribute :resolved_at, :utc_datetime_usec, public?: true, allow_nil?: true
  end

  relationships do
    has_many :comments, AshMetrics.Test.PgTicketComment,
      public?: true,
      destination_attribute: :ticket_id
  end

  calculations do
    calculate :discussion, :atom, expr(if comment_count > 1, do: :busy, else: :quiet)
    calculate :broken, :integer, expr(fragment("1 / 0"))
    calculate :faulty, :atom, fn _records, _context -> raise "the calculation failed" end
  end

  aggregates do
    count :comment_count, :comments
    exists :commented, :comments
  end

  actions do
    defaults [:read, :destroy]

    create :open do
      accept [:priority, :assignee]

      change set_attribute(:status, :open)
      change AshMetrics.increment_on_change(:transitions, :status)
    end

    update :update_status do
      require_atomic? false
      accept [:status, :resolved_at]

      change AshMetrics.increment_on_change(:transitions, :status)

      change AshMetrics.observe_elapsed(:time_to_resolve,
               from: :inserted_at,
               to: :resolved_at
             ),
             where: [attribute_equals(:status, :resolved)]
    end

    # `:update_status`'s counter, followed by an `after_action` hook that fails
    # the action after the counter's hook ran.
    update :update_status_then_fail do
      require_atomic? false
      accept [:status]

      change AshMetrics.increment_on_change(:transitions, :status)

      change after_action(fn _changeset, _record, _context ->
               {:error, "failed after the write"}
             end)
    end

    # Counts into the counter whose tags are aggregates.
    update :escalate do
      accept [:status]

      change AshMetrics.increment_on_write(:escalations, :status)
    end

    # Counts into the counter whose tag Postgres fails to compute.
    update :audit do
      accept [:status]

      change AshMetrics.increment_on_write(:audits, :status)
    end

    # Counts into the counter whose tag raises in Elixir, off the atomic path,
    # so that a changeset built outside a transaction keeps its
    # `after_transaction` hook when it runs inside one.
    update :review do
      require_atomic? false
      accept [:status]

      change AshMetrics.increment_on_write(:reviews, :status)
    end

    # Both atomic-capable changes on one action that keeps Ash's default
    # `require_atomic? true`.
    update :resolve do
      accept [:status, :resolved_at]

      change AshMetrics.increment_on_write(:transitions, :status)

      change AshMetrics.observe_elapsed(:time_to_resolve,
               from: :inserted_at,
               to: :resolved_at
             )
    end
  end
end
