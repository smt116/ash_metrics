defmodule AshMetrics.NameBuilder do
  @moduledoc """
  Builds the metric name of a resource's metric.

  Applies a naming convention in one place instead of at every declaration.
  Configure one with:

      config :ash_metrics, name_builder: MyApp.NameBuilder

  The configured value must be a module; there is no function-capture or MFA
  form. The default is `AshMetrics.NameBuilder.Default`.

  The name a builder returns does not include the aggregation suffix; that is
  appended when the declarations are compiled to metric definitions.
  """

  alias AshMetrics.Config

  @doc """
  Returns the metric name for `metric` on `resource`, without an aggregation
  suffix.

  `prefix` is the configured `AshMetrics.Config.prefix!/0`.
  """
  @callback build(prefix :: String.t(), resource :: module(), metric :: atom()) :: String.t()

  @doc """
  Builds the name of `metric` on `resource` with the configured builder.
  """
  @spec build(module(), atom()) :: String.t()
  def build(resource, metric) do
    Config.name_builder().build(Config.prefix!(), resource, metric)
  end
end
