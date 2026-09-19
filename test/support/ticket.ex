defmodule AshMetrics.Test.Ticket do
  @moduledoc false
  # The resource the action changes are exercised against: a status an action
  # writes, two more attributes the counter tags with, and the timestamps the
  # elapsed distribution measures between.
  use Ash.Resource,
    domain: AshMetrics.Test.Queue,
    data_layer: Ash.DataLayer.Ets,
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

  attributes do
    uuid_primary_key :id

    # `:archived` is the one status the counter does not enumerate, so that a
    # write the closed tag excludes can be exercised.
    attribute :status, :atom,
      public?: true,
      constraints: [one_of: [:open, :in_progress, :resolved, :closed, :archived]]

    attribute :priority, :atom, public?: true, constraints: [one_of: [:low, :high]]
    attribute :assignee, :string, public?: true

    create_timestamp :inserted_at

    attribute :resolved_at, :utc_datetime_usec, public?: true, allow_nil?: true

    # Naive, so that an elapsed time between the two kinds of timestamp can be
    # measured.
    attribute :acknowledged_at, :naive_datetime, public?: true, allow_nil?: true
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

    # Measures to `:now` rather than to an attribute, and writes nothing.
    update :touch do
      require_atomic? false

      change AshMetrics.observe_elapsed(:time_to_resolve, from: :inserted_at)
    end

    # Measures between a utc and a naive timestamp.
    update :acknowledge do
      require_atomic? false
      accept [:acknowledged_at]

      change AshMetrics.observe_elapsed(:time_to_resolve,
               from: :inserted_at,
               to: :acknowledged_at
             )
    end

    # Counts every write of the status rather than every change of it.
    create :submit do
      accept [:priority, :assignee]

      change set_attribute(:status, :open)
      change AshMetrics.increment_on_write(:transitions, :status)
    end

    # Keeps Ash's default `require_atomic? true`.
    update :write_status do
      accept [:status]

      change AshMetrics.increment_on_write(:transitions, :status)
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

    # `:resolve` again, with a `where:` reading an attribute, which takes the
    # action out of the atomic path it did not opt out of.
    update :resolve_when_resolved do
      accept [:status, :resolved_at]

      change AshMetrics.observe_elapsed(:time_to_resolve,
               from: :inserted_at,
               to: :resolved_at
             ),
             where: [attribute_equals(:status, :resolved)]
    end

    # Carries the change while touching another attribute, so that a status
    # that did not move can be shown to emit nothing.
    update :rename do
      require_atomic? false
      accept [:assignee]

      change AshMetrics.increment_on_change(:transitions, :status)
    end
  end
end
