defmodule AshMetrics.Info do
  @moduledoc """
  Introspection of the `metrics` section of a resource.

  `Spark.InfoGenerator` supplies the per-option accessors; the lookups below
  are what the rest of the package uses.
  """

  use Spark.InfoGenerator, extension: AshMetrics, sections: [:metrics]

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Counter
  alias AshMetrics.Dsl.Distribution
  alias AshMetrics.Dsl.Gauge

  @typedoc "Any metric declaration that can appear in a `metrics` block."
  @type metric :: Counter.t() | Distribution.t() | Gauge.t()

  @typedoc "A resource, or the DSL state of a resource being compiled."
  @type resource :: module() | Spark.Dsl.t()

  @doc """
  Fetches a single metric declaration by name.

  Returns `{:ok, metric}` or `:error`. See `metric!/2` for the raising variant.
  """
  @spec metric(resource(), atom()) :: {:ok, metric()} | :error
  def metric(resource, name) do
    case Enum.find(metrics(resource), &(&1.name == name)) do
      nil -> :error
      metric -> {:ok, metric}
    end
  end

  @doc """
  Fetches a single metric declaration by name, raising if it is not declared.

  The `ArgumentError` lists the metrics the resource does declare.
  """
  @spec metric!(resource(), atom()) :: metric()
  def metric!(resource, name) do
    case metric(resource, name) do
      {:ok, metric} ->
        metric

      :error ->
        raise ArgumentError,
              "no metric #{inspect(name)} is declared on #{inspect(resource)}. " <>
                "Declared metrics: #{available(resource)}"
    end
  end

  @doc """
  The name segment used for a resource in its metric names.

  This is the `name` option of the `metrics` section when set, and
  `Ash.Resource.Info.short_name/1` otherwise.
  """
  @spec name(resource()) :: atom()
  def name(resource) do
    case metrics_name(resource) do
      {:ok, name} when not is_nil(name) -> name
      _otherwise -> ResourceInfo.short_name(resource)
    end
  end

  @doc """
  The `AshMetrics.Poller` that polls a resource's gauges.

  This is the `poller` option of the `metrics` section when set, and the
  configured `AshMetrics.Config.poller/0` otherwise. Read this rather than the
  configuration directly, since a resource may override it.
  """
  @spec poller(resource()) :: module()
  def poller(resource) do
    case metrics_poller(resource) do
      {:ok, poller} when not is_nil(poller) -> poller
      _otherwise -> Config.poller()
    end
  end

  @spec available(resource()) :: String.t()
  defp available(resource) do
    case Enum.map(metrics(resource), & &1.name) do
      [] -> "none"
      names -> Enum.map_join(names, ", ", &inspect/1)
    end
  end
end
