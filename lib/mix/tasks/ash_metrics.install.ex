if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshMetrics.Install do
    @shortdoc "Installs AshMetrics. Should be run with `mix igniter.install ash_metrics`"

    @moduledoc """
    #{@shortdoc}

    Writes the two pieces of configuration that AshMetrics cannot default:

    * `prefix`, the first segment of every metric name, set to the name of
      the application being installed into. See `AshMetrics.Config.prefix!/0`.
    * `otp_app`, the application whose Ash domains are searched for resources
      that declare metrics.

    Everything else AshMetrics reads has a default; the task prints those
    rather than writing them out.

    It then wires the metrics up:

    * The module that imports `Telemetry.Metrics` and defines `metrics/0` —
      `MyAppWeb.Telemetry` in a generated Phoenix application — has
      `++ AshMetrics.metrics()` appended to what that function returns, so
      that the reporter it already starts ships the declared metrics too.
      When there is no such module, the snippet to add is printed instead.
    * `AshMetrics.Supervisor` is added to the application's children, after
      the repositories and Oban, because a gauge is answered by a query.

    Nothing already configured is overwritten, so the task is safe to run
    again.

        mix igniter.install ash_metrics
    """

    use Igniter.Mix.Task

    # Aliased under a prefix, because `Igniter.Project.Application` would
    # otherwise shadow Elixir's own `Application`.
    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Libs.Ecto, as: EctoLib
    alias Igniter.Project.Application, as: ProjectApplication
    alias Igniter.Project.Config, as: ProjectConfig
    alias Igniter.Project.Deps, as: ProjectDeps
    alias Igniter.Project.Formatter, as: ProjectFormatter
    alias Igniter.Project.Module, as: ProjectModule
    alias Sourceror.Zipper

    @example "mix igniter.install ash_metrics"

    # Printed rather than written into `config/config.exs` as comments:
    # Sourceror gives a comment emitted by
    # `Igniter.Project.Config.configure_group/6` line 0, which lands it above
    # `import Config`.
    @optional_keys """
    Everything else AshMetrics reads has a default. These are they:

        config :ash_metrics,
          name_builder: AshMetrics.NameBuilder.Default,
          tag_extractor: AshMetrics.TagExtractor.Default,
          backend: AshMetrics.Backend.Noop,
          poller: AshMetrics.Poller.GenServer,
          tenant_source: nil

    `poller` belongs in `config/config.exs` with the two keys that were
    written: it is read while resources compile. `tenant_source` is needed
    only by an application that declares a gauge on a resource which has to be
    polled per tenant.
    """

    # Printed when the application already depends on `ash_oban`.
    @ash_oban_poller """
    This application depends on `ash_oban`, so gauges can be polled from
    Oban's cron rather than the default timer:

        config :ash_metrics, poller: AshMetrics.Poller.AshOban

    or, for one resource at a time:

        metrics do
          poller AshMetrics.Poller.AshOban
        end

    `poller` is read while resources compile, so it belongs in
    `config/config.exs`. The poller itself takes:

        config :ash_metrics, AshMetrics.Poller.AshOban,
          queue: :default,
          max_attempts: 1

    A resource that selects it must use the `AshOban` extension, every gauge's
    `period` must be a whole number of minutes, hours or one day, and the
    queue must exist in the Oban configuration built with `AshOban.config/2`
    with `Oban.Plugins.Cron` enabled, or the schedules are never registered.

    See `AshMetrics.Poller.AshOban`.
    """

    # Printed when nothing in the application looks like the module a
    # reporter is configured from, which is the case for an application that
    # runs no reporter yet.
    @no_telemetry_module """
    No module that imports `Telemetry.Metrics` and defines `metrics/0` was
    found, so nothing reports the declared metrics yet. Start a reporter with
    them:

        {Telemetry.Metrics.ConsoleReporter, metrics: AshMetrics.metrics()}

    If you do already run a reporter, splice `AshMetrics.metrics/0` into the
    list of metrics it is given, rather than starting a second one:
    `my_own_metrics() ++ AshMetrics.metrics()`.
    """

    @impl Igniter.Mix.Task
    def info(_argv, _source) do
      %Igniter.Mix.Task.Info{
        group: :ash_metrics,
        example: @example,
        schema: [],
        composes: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      app_name = ProjectApplication.app_name(igniter)

      igniter
      |> ProjectFormatter.import_dep(:ash_metrics)
      |> configure(app_name)
      |> add_to_reporter()
      |> supervise()
      |> Igniter.add_notice(@optional_keys)
      |> note_ash_oban_poller()
    end

    @spec note_ash_oban_poller(Igniter.t()) :: Igniter.t()
    defp note_ash_oban_poller(igniter) do
      if ProjectDeps.has_dep?(igniter, :ash_oban) do
        Igniter.add_notice(igniter, @ash_oban_poller)
      else
        igniter
      end
    end

    # `configure_new/5`, not `configure/6`: a `prefix` an adopter has already
    # chosen must not be replaced by the application name.
    @spec configure(Igniter.t(), atom()) :: Igniter.t()
    defp configure(igniter, app_name) do
      igniter
      |> ProjectConfig.configure_new("config.exs", :ash_metrics, [:prefix], to_string(app_name))
      |> ProjectConfig.configure_new("config.exs", :ash_metrics, [:otp_app], app_name)
    end

    @spec add_to_reporter(Igniter.t()) :: Igniter.t()
    defp add_to_reporter(igniter) do
      case ProjectModule.find_all_matching_modules(igniter, &telemetry_module?(&1, &2)) do
        {igniter, []} -> Igniter.add_notice(igniter, @no_telemetry_module)
        {igniter, modules} -> Enum.reduce(modules, igniter, &append_metrics(&2, &1))
      end
    end

    # A module that both imports `Telemetry.Metrics` and defines `metrics/0`
    # is where a reporter is told what to report. Every match is updated: an
    # umbrella or a hand-written tree may have more than Phoenix's one.
    @spec telemetry_module?(module(), Zipper.t()) :: boolean()
    defp telemetry_module?(_module, zipper) do
      imports_telemetry_metrics?(zipper) and match?({:ok, _zipper}, metrics_body(zipper))
    end

    @spec imports_telemetry_metrics?(Zipper.t()) :: boolean()
    defp imports_telemetry_metrics?(zipper) do
      Enum.any?([:import, :use], fn call ->
        match?(
          {:ok, _zipper},
          Function.move_to_function_call(zipper, call, [1, 2], fn zipper ->
            Function.argument_equals?(zipper, 0, Telemetry.Metrics)
          end)
        )
      end)
    end

    @spec metrics_body(Zipper.t()) :: {:ok, Zipper.t()} | :error
    defp metrics_body(zipper), do: Function.move_to_def(zipper, :metrics, 0)

    @spec append_metrics(Igniter.t(), module()) :: Igniter.t()
    defp append_metrics(igniter, module) do
      # The module was found by `find_all_matching_modules/2` a moment ago, so
      # `find_and_update_module/3` cannot fail to find it again.
      {:ok, igniter} = ProjectModule.find_and_update_module(igniter, module, &append_to_body/1)

      igniter
    end

    @spec append_to_body(Zipper.t()) :: {:ok, Zipper.t()} | :error
    defp append_to_body(zipper) do
      with {:ok, zipper} <- metrics_body(zipper) do
        if already_appended?(zipper), do: {:ok, zipper}, else: {:ok, append_call(zipper)}
      end
    end

    @spec already_appended?(Zipper.t()) :: boolean()
    defp already_appended?(zipper) do
      match?({:ok, _zipper}, Function.move_to_function_call(zipper, {AshMetrics, :metrics}, 0))
    end

    # The value of `metrics/0` is whatever its last expression evaluates to.
    # Appending to that expression leaves an application's own metrics, and
    # whatever it computes them from, untouched.
    @spec append_call(Zipper.t()) :: Zipper.t()
    defp append_call(zipper) do
      zipper = last_expression(zipper)

      Zipper.replace(
        zipper,
        {:++, [], [Zipper.node(zipper), Sourceror.parse_string!("AshMetrics.metrics()")]}
      )
    end

    @spec last_expression(Zipper.t()) :: Zipper.t()
    defp last_expression(zipper) do
      case Zipper.node(zipper) do
        {:__block__, _meta, [_first, _second | _rest]} ->
          zipper |> Zipper.down() |> Zipper.rightmost()

        _node ->
          Common.maybe_move_to_single_child_block(zipper)
      end
    end

    @spec supervise(Igniter.t()) :: Igniter.t()
    defp supervise(igniter) do
      {igniter, repos} = EctoLib.list_repos(igniter)

      ProjectApplication.add_new_child(igniter, AshMetrics.Supervisor, after: repos ++ [Oban])
    end
  end
else
  defmodule Mix.Tasks.AshMetrics.Install do
    @shortdoc "Installs AshMetrics. Should be run with `mix igniter.install ash_metrics`"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_metrics.install' requires igniter to be run.

      Please add `{:igniter, "~> 0.6", only: [:dev, :test]}` to your
      dependencies, run `mix deps.get`, and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
