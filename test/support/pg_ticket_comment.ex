defmodule AshMetrics.Test.PgTicketComment do
  @moduledoc false
  # The related rows the aggregates of `AshMetrics.Test.PgTicket` count.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "pg_ticket_comments"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :ticket, AshMetrics.Test.PgTicket, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:ticket_id]]
  end
end
