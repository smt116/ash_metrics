# The Postgres backed tests are tagged `:postgres` and excluded unless they
# were asked for with `--include postgres`, which `mix test.integration` does.
# The repo is started only then, so a plain `mix test` needs no database and no
# container running.
postgres? = :postgres in List.wrap(ExUnit.configuration()[:include])

unless postgres? do
  ExUnit.configure(exclude: [:postgres])
end

if postgres? do
  {:ok, _pid} = AshMetrics.Test.Repo.start_link()
end

ExUnit.start()
