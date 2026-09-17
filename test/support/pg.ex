defmodule AshMetrics.Test.Pg do
  @moduledoc false
  # Holds the resources backed by Postgres rather than by ETS. They are only
  # ever read by the `:postgres` tagged integration tests.
  use Ash.Domain

  resources do
    resource AshMetrics.Test.PgJob
  end
end
