defmodule AshMetrics.Test.Ets do
  @moduledoc false
  # Empties the ETS tables behind the gauge resources.
  #
  # `Ash.DataLayer.Ets.stop/2` deletes a table by killing the process that owns
  # it, which is asynchronous and therefore races the next seed. Emptying the
  # table in place is synchronous, and the tables are public, so a test process
  # may empty one the poller process is reading.
  #
  # Every test that seeds data has to call this, and has to be `async: false`:
  # the tables are named after the resource and are shared by the whole node.

  alias Ash.DataLayer.Ets
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.SchemaJob
  alias AshMetrics.Test.TenantJob
  alias AshMetrics.Test.Tenants

  @spec clear!() :: :ok
  def clear! do
    clear!(Job)
    clear!(TenantJob)

    Enum.each(Tenants.list_tenants(), &clear!(SchemaJob, &1))
  end

  @spec clear!(module(), term()) :: :ok
  def clear!(resource, tenant \\ nil) do
    case Ets.table_name(resource, tenant, false) do
      :no_table ->
        :ok

      {:ok, table} ->
        empty(table)
    end
  end

  @spec empty(atom()) :: :ok
  defp empty(table) do
    case :ets.whereis(table) do
      :undefined -> :ok
      tid -> true = :ets.delete_all_objects(tid)
    end

    :ok
  end
end
