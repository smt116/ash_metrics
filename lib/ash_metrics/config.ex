defmodule AshMetrics.Config do
  @moduledoc """
  Reads the `:ash_metrics` application environment.

  Everything has a default except `prefix` and `otp_app`, which raise when
  absent.

      config :ash_metrics,
        prefix: "myapp",
        otp_app: :my_app,
        name_builder: AshMetrics.NameBuilder.Default,
        tag_extractor: AshMetrics.TagExtractor.Default,
        backend: AshMetrics.Backend.Noop,
        poller: AshMetrics.Poller.GenServer,
        poll: true

  `tenant_source` has no default and is not required either: it is needed only
  by an application that declares a gauge on a resource which has to be polled
  per tenant. See `AshMetrics.TenantSource`.

      config :ash_metrics, tenant_source: MyApp.Tenants

  The values are read on each call, so most of them can be overridden from
  `config/runtime.exs`. Two are read while resources compile and must be set in
  `config/config.exs`: `prefix`, which a verifier requires, and `poller`, which
  decides whether Oban schedules are generated for a resource. A `poller` that
  differs between compile time and runtime leaves gauges with no poller at all.
  """

  @app :ash_metrics

  @doc """
  The metric name prefix. Required.

  Raises when it is missing or not a non-empty string. It must be set in
  `config/config.exs` and is never derived from `otp_app`.
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
  Whether the pollers of the declared gauges are started. Defaults to `true`.

  With `false`, `AshMetrics.child_specs/1` returns no poller's children; the
  backend's children and the compiled metric definitions are the same either
  way. A poller that runs no process of its own, such as
  `AshMetrics.Poller.AshOban`, polls regardless of this key.

      config :ash_metrics, poll: false
  """
  @spec poll?() :: boolean()
  def poll?, do: Application.get_env(@app, :poll, true)

  @doc """
  The Oban queue the gauges polled by `AshMetrics.Poller.AshOban` run in.

  Defaults to `:default`. The queue has to exist in the host application's
  Oban configuration; `AshOban.config/2` refuses to build a crontab entry for
  a queue that does not.

      config :ash_metrics, AshMetrics.Poller.AshOban, queue: :metrics
  """
  @spec ash_oban_queue() :: atom()
  def ash_oban_queue, do: ash_oban(:queue, :default)

  @doc """
  How many times a poll scheduled by `AshMetrics.Poller.AshOban` is attempted.

  Defaults to one; see `AshMetrics.Poller.AshOban`.

      config :ash_metrics, AshMetrics.Poller.AshOban, max_attempts: 2
  """
  @spec ash_oban_max_attempts() :: pos_integer()
  def ash_oban_max_attempts, do: ash_oban(:max_attempts, 1)

  @spec ash_oban(atom(), term()) :: term()
  defp ash_oban(key, default) do
    @app
    |> Application.get_env(AshMetrics.Poller.AshOban, [])
    |> Keyword.get(key, default)
  end

  @doc """
  How long `AshMetrics.Backend.Otel` waits for one gauge to be counted.

  In milliseconds, defaulting to 5000. A count that overruns it is killed;
  see `AshMetrics.Backend.Otel`.

      config :ash_metrics, AshMetrics.Backend.Otel, timeout: 5_000
  """
  @spec otel_timeout() :: pos_integer()
  def otel_timeout, do: otel(:timeout, 5_000)

  @spec otel(atom(), term()) :: term()
  defp otel(key, default) do
    @app
    |> Application.get_env(AshMetrics.Backend.Otel, [])
    |> Keyword.get(key, default)
  end

  @doc """
  The configured `AshMetrics.TenantSource`, or `nil` when there is none.

  There is no default: only an application that declares a gauge on a resource
  which has to be polled per tenant needs one. See `AshMetrics.TenantSource`.
  """
  @spec tenant_source() :: module() | nil
  def tenant_source, do: Application.get_env(@app, :tenant_source)

  @doc """
  The configured `AshMetrics.TenantSource`, raising when there is none.
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

        A gauge on a resource using Ash's `:context` multitenancy strategy, or
        its `:attribute` strategy without `global? true`, is polled once per
        tenant, and only the application can say which tenants exist.
        """
    end
  end
end
