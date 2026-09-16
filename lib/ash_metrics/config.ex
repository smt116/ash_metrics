defmodule AshMetrics.Config do
  @moduledoc """
  Reads the `:ash_metrics` application environment.

  Everything has a default except `prefix` and `otp_app`, which have no sane
  default and raise when absent. See `prefix!/0` for why `prefix` is required
  rather than derived.

      config :ash_metrics,
        prefix: "myapp",
        otp_app: :my_app,
        outcome_tag: :outcome,
        name_builder: AshMetrics.NameBuilder.Default,
        tag_extractor: AshMetrics.TagExtractor.Default,
        backend: AshMetrics.Backend.Noop,
        poller: AshMetrics.Poller.GenServer

  `tenant_source` has no default and is not required either: it is needed only
  by an application whose resources use Ash's `:context` multitenancy strategy
  and declare gauges.

      config :ash_metrics, tenant_source: MyApp.Tenants

  The values are read on each call rather than captured in a module attribute,
  so that a host application can override them from `config/runtime.exs` for
  everything except `prefix`, which a compile-time verifier requires.
  """

  @app :ash_metrics

  @doc """
  The metric name prefix. Required.

  Raises when it is missing or not a non-empty string. It is required rather
  than derived from `otp_app` because a compile-time lookup of the owning
  application is unreliable — `Application.get_application/1` returns `nil`
  while the owning application is itself being compiled — and a metric name is
  a permanent contract that cannot be quietly wrong.
  """
  @spec prefix!() :: String.t()
  def prefix! do
    case Application.get_env(@app, :prefix) do
      prefix when is_binary(prefix) and prefix != "" ->
        prefix

      other ->
        raise ArgumentError, """
        `prefix` must be set to a non-empty string in the compile-time configuration \
        of #{inspect(@app)}, got: #{inspect(other)}.

        Add this to `config/config.exs`:

            config :ash_metrics, prefix: "myapp"

        `config/runtime.exs` alone is too late: a compile-time verifier rejects
        a resource that declares metrics unless the prefix is configured when
        the resource compiles.
        """
    end
  end

  @doc """
  The OTP application whose Ash domains are searched by AshMetrics.metrics/0.

  Raises when it is missing or not an atom.
  """
  @spec otp_app!() :: atom()
  def otp_app! do
    case Application.get_env(@app, :otp_app) do
      otp_app when is_atom(otp_app) and not is_nil(otp_app) ->
        otp_app

      other ->
        raise ArgumentError, """
        `otp_app` must be set to an application name in the configuration of \
        #{inspect(@app)}, got: #{inspect(other)}.

        Add this to `config/config.exs`:

            config :ash_metrics, otp_app: :my_app

        It is used to find the Ash domains, and through them the resources,
        that declare metrics.
        """
    end
  end

  @doc """
  The tag key that carries a counter's outcome. Defaults to `:outcome`.
  """
  @spec outcome_tag() :: atom()
  def outcome_tag, do: Application.get_env(@app, :outcome_tag, :outcome)

  @doc """
  The `AshMetrics.NameBuilder` implementation used to build metric names.
  """
  @spec name_builder() :: module()
  def name_builder, do: Application.get_env(@app, :name_builder, AshMetrics.NameBuilder.Default)

  @doc """
  The `AshMetrics.TagExtractor` implementation used to derive tags from
  emission metadata.
  """
  @spec tag_extractor() :: module()
  def tag_extractor,
    do: Application.get_env(@app, :tag_extractor, AshMetrics.TagExtractor.Default)

  @doc """
  The `AshMetrics.Backend` implementation the host application starts.
  """
  @spec backend() :: module()
  def backend, do: Application.get_env(@app, :backend, AshMetrics.Backend.Noop)

  @doc """
  The `AshMetrics.Poller` implementation that polls the declared gauges.
  """
  @spec poller() :: module()
  def poller, do: Application.get_env(@app, :poller, AshMetrics.Poller.GenServer)

  @doc """
  The configured `AshMetrics.TenantSource`, or `nil` when there is none.

  There is no default: only an application whose resources use Ash's
  `:context` multitenancy strategy needs one, and no default could enumerate
  its tenants.
  """
  @spec tenant_source() :: module() | nil
  def tenant_source, do: Application.get_env(@app, :tenant_source)

  @doc """
  The configured `AshMetrics.TenantSource`, raising when there is none.

  Raises rather than returning an empty list of tenants, because a gauge on a
  `:context` multitenant resource that is polled for no tenants emits nothing
  at all, which is indistinguishable from a working metric whose value is zero.
  """
  @spec tenant_source!() :: module()
  def tenant_source! do
    case tenant_source() do
      module when is_atom(module) and not is_nil(module) ->
        module

      other ->
        raise ArgumentError, """
        `tenant_source` must be set to a module implementing \
        `AshMetrics.TenantSource` in the configuration of #{inspect(@app)}, \
        got: #{inspect(other)}.

        Add this to `config/config.exs`:

            config :ash_metrics, tenant_source: MyApp.Tenants

        A gauge on a resource using Ash's `:context` multitenancy strategy is
        polled once per tenant, and only the application can say which
        tenants exist.
        """
    end
  end
end
