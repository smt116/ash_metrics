defmodule AshMetrics.Test.PgTicket do
  @moduledoc false
  # `AshMetrics.Test.Ticket` again, on Postgres instead of ETS, so that the
  # action changes can be exercised against a data layer that runs bulk
  # updates and bulk creates for real.
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
