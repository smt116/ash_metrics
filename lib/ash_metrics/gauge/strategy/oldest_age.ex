defmodule AshMetrics.Gauge.Strategy.OldestAge do
  @moduledoc """
  Reports, per group, the age of the oldest row matching a gauge.

      gauge :backlog_age,
        filter: expr(status == :pending),
        group_by: [:provider],
        strategy: AshMetrics.Gauge.Strategy.OldestAge

      gauge :queue_age,
        filter: expr(status == :pending),
        strategy: {AshMetrics.Gauge.Strategy.OldestAge, attribute: :queued_at}

  ## Options

  * `:attribute` — the timestamp attribute of the resource to measure from.
    Defaults to `:inserted_at`. Its type must be `:utc_datetime`,
    `:utc_datetime_usec`, `:naive_datetime` or `:datetime`, or an
    `Ash.Type.NewType` of one of them.

  A gauge naming an attribute that does not exist or has another type,
  declaring any other option, or on a resource whose data layer does not
  support an Ash `:min` aggregate, is rejected while the resource compiles.

  ## Value

  A group's value is the whole seconds from the earliest value of `attribute`
  among its rows to the time of the poll, as a non-negative integer. A
  `:naive_datetime` is taken to be in UTC. A timestamp later than the poll
  reads 0.

  Rows whose `attribute` is `nil` are ignored, and a group whose rows all hold
  `nil` reads 0. A gauge with no `group_by` and no matching row reads 0 as
  well, so an empty set and a row written within the last second read the
  same.

  ## Cost

  The queries of `AshMetrics.Gauge.Strategy.Count`, with an Ash `:min`
  aggregate over `attribute` in place of each count: `1 + groups` per poll,
  once per tenant for a resource polled per tenant, every one with
  `authorize?: false`.
  """

  @behaviour AshMetrics.Gauge.Strategy

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type.NewType
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Gauge.Strategy
  alias AshMetrics.Gauge.Strategy.PerGroup

  @options [:attribute]

  @types [
    Ash.Type.UtcDatetime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.NaiveDatetime,
    Ash.Type.DateTime
  ]

  @impl AshMetrics.Gauge.Strategy
  @spec verify(Spark.Dsl.t(), Gauge.t()) :: :ok | {:error, String.t()}
  def verify(dsl_state, %Gauge{} = gauge) do
    with :ok <- verify_options(gauge.strategy_opts),
         :ok <- verify_attribute(dsl_state, attribute(gauge)),
         do: verify_data_layer(dsl_state)
  end

  @impl AshMetrics.Gauge.Strategy
  @spec compute(module(), Gauge.t(), keyword()) :: {:ok, [Strategy.group()]} | {:error, term()}
  def compute(resource, %Gauge{} = gauge, opts) do
    attribute = attribute(gauge)
    now = DateTime.utc_now()

    PerGroup.compute(resource, gauge, opts, &oldest_age(&1, attribute, now))
  end

  @doc false
  @spec attribute(Gauge.t()) :: atom()
  def attribute(%Gauge{strategy_opts: opts}), do: Keyword.get(opts, :attribute, :inserted_at)

  @doc false
  @spec age(DateTime.t() | NaiveDateTime.t() | nil, DateTime.t()) :: non_neg_integer()
  def age(nil, _now), do: 0
  def age(%DateTime{} = oldest, now), do: max(DateTime.diff(now, oldest, :second), 0)
  def age(%NaiveDateTime{} = oldest, now), do: age(DateTime.from_naive!(oldest, "Etc/UTC"), now)

  @spec oldest_age(Ash.Query.t(), atom(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp oldest_age(query, attribute, now) do
    case Ash.aggregate(query, {:oldest, :min, field: attribute}, authorize?: false) do
      {:ok, %{oldest: oldest}} -> {:ok, age(oldest, now)}
      {:error, error} -> {:error, error}
    end
  end

  @spec verify_options(keyword()) :: :ok | {:error, String.t()}
  defp verify_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown option #{Enum.map_join(unknown, ", ", &inspect/1)}. " <>
           "The only option is :attribute."}
    end
  end

  @spec verify_attribute(Spark.Dsl.t(), atom()) :: :ok | {:error, String.t()}
  defp verify_attribute(dsl_state, name) do
    case ResourceInfo.attribute(dsl_state, name) do
      nil ->
        names = dsl_state |> ResourceInfo.attributes() |> Enum.map_join(", ", &inspect(&1.name))

        {:error,
         "it measures from #{inspect(name)}, which is not an attribute of this " <>
           "resource. Name a timestamp attribute with `attribute:`. Declared " <>
           "attributes: #{names}"}

      %{type: type} ->
        if unwrap(type) in @types do
          :ok
        else
          {:error,
           "it measures from #{inspect(name)}, whose type #{inspect(type)} is " <>
             "not a timestamp. The attribute must be a :utc_datetime, " <>
             ":utc_datetime_usec, :naive_datetime or :datetime."}
        end
    end
  end

  @spec verify_data_layer(Spark.Dsl.t()) :: :ok | {:error, String.t()}
  defp verify_data_layer(dsl_state) do
    if Ash.DataLayer.data_layer_can?(dsl_state, {:query_aggregate, :min}) do
      :ok
    else
      {:error,
       "it reads an Ash :min aggregate, which this resource's data layer " <>
         "#{inspect(Ash.DataLayer.data_layer(dsl_state))} does not support."}
    end
  end

  @spec unwrap(term()) :: term()
  defp unwrap(type) when is_atom(type) do
    if match?({:module, _module}, Code.ensure_compiled(type)) and NewType.new_type?(type),
      do: unwrap(NewType.subtype_of(type)),
      else: type
  end

  defp unwrap(type), do: type
end
