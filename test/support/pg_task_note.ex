defmodule AshMetrics.Test.PgTaskNote do
  @moduledoc false
  # The related rows a gauge on `AshMetrics.Test.PgTask` filters through.
  use Ash.Resource,
    domain: AshMetrics.Test.Pg,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "pg_task_notes"
    repo AshMetrics.Test.Repo
  end

  attributes do
    uuid_primary_key :id
  end

  relationships do
    belongs_to :task, AshMetrics.Test.PgTask, public?: true, allow_nil?: false
  end

  actions do
    defaults [:read, :destroy, create: [:task_id]]
  end
end
