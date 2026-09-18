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
