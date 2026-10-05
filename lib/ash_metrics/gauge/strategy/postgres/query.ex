if Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AshMetrics.Gauge.Strategy.Postgres.Query do
    @moduledoc false
    # The Ecto query behind a gauge on an `AshPostgres.DataLayer` resource, for
    # a strategy that computes every group in one statement.
    #
    # `rows/3` builds the query `Ash.count/2` would run for the same gauge: the
    # resource's base filter, the gauge's filter, the primary read action's
    # preparations and filter, and the tenant, as a schema prefix under
    # `:context` multitenancy or as a filter on the tenant attribute under
    # `:attribute`. Selection is dropped. A query that is distinct, limited or
    # offset is wrapped, ordering included, in a subquery that grouping then
    # reads; any other query loses its ordering. A distinct query is made
    # distinct on the gauge's `group_by` as well, so that each group keeps the
    # rows a read restricted to that group would return.
    #
    # A value read from the rows is selected untyped and loaded through its
    # attribute's Ash type by `cast/3`, on every path: the columns of a
    # subquery carry no type, so `field/2` or `map/2` alone would return them
    # as Postgrex decodes them.

    import Ecto.Query

    alias Ash.Error.Invalid.NoPrimaryAction
    alias Ash.Error.Invalid.TenantRequired
    alias Ash.Resource.Info, as: ResourceInfo
    alias AshMetrics.Dsl.Gauge
    alias AshPostgres.DataLayer.Info, as: PostgresInfo

    require Ash.Expr

    @spec verify(Spark.Dsl.t()) :: :ok | {:error, String.t()}
    def verify(dsl_state) do
      case Ash.DataLayer.data_layer(dsl_state) do
        AshPostgres.DataLayer ->
          :ok

        data_layer ->
          {:error,
           "it queries through AshPostgres.DataLayer, and this resource uses " <>
             "#{inspect(data_layer)}. Choose a strategy that reads through Ash, " <>
             "such as AshMetrics.Gauge.Strategy.Count."}
      end
    end

    @spec rows(module(), Gauge.t(), keyword()) :: {:ok, Ecto.Query.t()} | {:error, term()}
    def rows(resource, %Gauge{} = gauge, opts) do
      with {:ok, action} <- primary_read(resource),
           {:ok, query} <- resource |> query(gauge, opts, action) |> tenancy(),
           query = distinct_per_group(query, gauge.group_by),
           {:ok, query} <- Ash.Query.data_layer_query(query) do
        {:ok, strip(query)}
      else
        {:error, error} -> {:error, Ash.Error.to_error_class(error)}
      end
    end

    # Groups `query` by `group_by` and returns, per group, its tags, each loaded
    # with `cast/3`, and what `value` selects for it, passed through `load`.
    @spec grouped(
            module(),
            Ecto.Query.t(),
            [atom()],
            Ecto.Query.dynamic_expr(),
            (term() -> {:ok, term()} | {:error, term()})
          ) :: {:ok, [{AshMetrics.tags(), term()}]} | {:error, term()}
    def grouped(resource, query, group_by, value, load \\ &{:ok, &1}) do
      selected =
        group_by
        |> Enum.with_index(1)
        |> Map.new(fn {name, index} ->
          {index, dynamic([row], fragment("?", field(row, ^name)))}
        end)
        |> Map.put(0, value)

      with {:ok, rows} <-
             query |> group_by([row], ^group_by) |> select(^selected) |> then(&all(resource, &1)) do
        map_while_ok(rows, &group(resource, group_by, load, &1))
      end
    end

    # Loads `value`, as read from the column of the attribute `name`, through
    # that attribute's Ash type.
    @spec cast(module(), atom(), term()) :: {:ok, term()} | {:error, String.t()}
    def cast(resource, name, value) do
      %{type: type, constraints: constraints} = ResourceInfo.attribute(resource, name)

      case Ash.Type.cast_stored(type, value, constraints) do
        {:ok, value} ->
          {:ok, value}

        _error ->
          {:error,
           "cannot load #{inspect(value)}, read from #{inspect(name)}, as #{inspect(type)}"}
      end
    end

    @spec group(
            module(),
            [atom()],
            (term() -> {:ok, term()} | {:error, term()}),
            %{non_neg_integer() => term()}
          ) :: {:ok, {AshMetrics.tags(), term()}} | {:error, term()}
    defp group(resource, group_by, load, row) do
      with {:ok, tags} <- tags(resource, group_by, row),
           {:ok, value} <- load.(row[0]),
           do: {:ok, {tags, value}}
    end

    @spec tags(module(), [atom()], %{non_neg_integer() => term()}) ::
            {:ok, AshMetrics.tags()} | {:error, String.t()}
    defp tags(resource, group_by, row) do
      group_by
      |> Enum.with_index(1)
      |> map_while_ok(fn {name, index} ->
        with {:ok, value} <- cast(resource, name, row[index]), do: {:ok, {name, value}}
      end)
      |> case do
        {:ok, tags} -> {:ok, Map.new(tags)}
        {:error, error} -> {:error, error}
      end
    end

    @spec map_while_ok([term()], (term() -> {:ok, term()} | {:error, term()})) ::
            {:ok, [term()]} | {:error, term()}
    defp map_while_ok(enumerable, fun) do
      enumerable
      |> Enum.reduce_while({:ok, []}, fn element, {:ok, mapped} ->
        case fun.(element) do
          {:ok, value} -> {:cont, {:ok, [value | mapped]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
      |> case do
        {:ok, mapped} -> {:ok, Enum.reverse(mapped)}
        {:error, error} -> {:error, error}
      end
    end

    @spec all(module(), Ecto.Query.t()) :: {:ok, [term()]} | {:error, Exception.t()}
    def all(resource, query),
      do: run(resource, &PostgresInfo.repo(resource, :read).all(query, &1))

    @spec one(module(), Ecto.Query.t()) :: {:ok, term()} | {:error, Exception.t()}
    def one(resource, query),
      do: run(resource, &PostgresInfo.repo(resource, :read).one(query, &1))

    @spec run(module(), (keyword() -> term())) :: {:ok, term()} | {:error, Exception.t()}
    defp run(resource, call) do
      {:ok, call.(repo_opts(resource))}
    rescue
      error -> {:error, error}
    end

    @spec repo_opts(module()) :: keyword()
    defp repo_opts(resource) do
      schema = PostgresInfo.schema(resource)

      if ResourceInfo.multitenancy_strategy(resource) != :context and schema,
        do: [prefix: schema],
        else: []
    end

    @spec primary_read(module()) :: {:ok, Ash.Resource.Actions.Read.t()} | {:error, term()}
    defp primary_read(resource) do
      case ResourceInfo.primary_action(resource, :read) do
        nil ->
          {:error, NoPrimaryAction.exception(resource: resource, type: :read)}

        action ->
          {:ok, action}
      end
    end

    @spec query(module(), Gauge.t(), keyword(), Ash.Resource.Actions.Read.t()) :: Ash.Query.t()
    defp query(resource, %Gauge{} = gauge, opts, action) do
      resource
      |> Ash.Query.new()
      |> filter(gauge.filter)
      |> tenant(Keyword.get(opts, :tenant))
      |> Ash.Query.for_read(action.name, %{}, authorize?: false)
      |> Ash.Query.set_domain(ResourceInfo.domain(resource))
    end

    @spec filter(Ash.Query.t(), term()) :: Ash.Query.t()
    defp filter(query, nil), do: query
    defp filter(query, filter), do: Ash.Query.do_filter(query, filter)

    @spec tenant(Ash.Query.t(), term()) :: Ash.Query.t()
    defp tenant(query, nil), do: query
    defp tenant(query, tenant), do: Ash.Query.set_tenant(query, tenant)

    # What a read applies for the tenant before it reaches the data layer:
    # `Ash.Query.data_layer_query/1` sets a `:context` tenant's schema prefix
    # itself, but neither filters on an `:attribute` tenant nor requires one.
    @spec tenancy(Ash.Query.t()) :: {:ok, Ash.Query.t()} | {:error, term()}
    defp tenancy(%Ash.Query{action: action} = query) do
      case action.multitenancy do
        :enforce -> with :ok <- require_tenant(query), do: {:ok, tenant_filter(query)}
        :allow_global -> {:ok, tenant_filter(query)}
        _bypass -> {:ok, query}
      end
    end

    @spec require_tenant(Ash.Query.t()) :: :ok | {:error, term()}
    defp require_tenant(%Ash.Query{resource: resource} = query) do
      if is_nil(ResourceInfo.multitenancy_strategy(resource)) or
           ResourceInfo.multitenancy_global?(resource) or not is_nil(query.tenant) do
        :ok
      else
        {:error, TenantRequired.exception(resource: resource)}
      end
    end

    @spec tenant_filter(Ash.Query.t()) :: Ash.Query.t()
    defp tenant_filter(%Ash.Query{resource: resource, tenant: tenant} = query) do
      attribute = ResourceInfo.multitenancy_attribute(resource)

      if tenant && attribute && ResourceInfo.multitenancy_strategy(resource) == :attribute do
        {module, function, args} = ResourceInfo.multitenancy_parse_attribute(resource)
        value = apply(module, function, [query.to_tenant | args])

        Ash.Query.do_filter(query, Ash.Expr.expr(^Ash.Expr.ref(attribute) == ^value))
      else
        query
      end
    end

    @spec distinct_per_group(Ash.Query.t(), [atom()]) :: Ash.Query.t()
    defp distinct_per_group(%Ash.Query{distinct: distinct} = query, group_by)
         when distinct in [nil, []] or group_by == [],
         do: query

    defp distinct_per_group(%Ash.Query{distinct: distinct} = query, group_by) do
      grouped = Ash.Query.distinct(%{query | distinct: []}, group_by)

      %{grouped | distinct: Enum.uniq(grouped.distinct ++ distinct)}
    end

    @spec strip(Ecto.Query.t()) :: Ecto.Query.t()
    defp strip(%Ecto.Query{} = query) do
      if query.distinct || query.limit || query.offset do
        from(row in subquery(exclude(query, :select)))
      else
        query
        |> exclude(:select)
        |> exclude(:order_by)
        |> Map.put(:windows, [])
      end
    end
  end
end
