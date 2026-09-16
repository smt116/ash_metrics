defmodule AshMetrics.NameBuilder do
  @moduledoc """
  Builds the metric name of a resource's metric.

  A name builder exists so that a house naming convention can be applied in one
  place instead of at every declaration. Configure one with:

      config :ash_metrics, name_builder: MyApp.NameBuilder

  Implementations are modules; there is no function-capture or MFA form, so the
  configured value is always inspectable and documentable. The default is
  `AshMetrics.NameBuilder.Default`.

  The name a builder returns does not include the aggregation suffix
  (`.count`, `.duration`). `Telemetry.Metrics` names carry that, and it is
  appended when the declarations are compiled to metric definitions.
  """

  alias AshMetrics.Config

  @doc """
  Returns the metric name for `metric` on `resource`, without an aggregation
  suffix.

  `prefix` is the configured `AshMetrics.Config.prefix!/0`, passed in rather
  than read again so that an implementation cannot disagree with the verifier
  about what the prefix is.
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
