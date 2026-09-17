defmodule AshMetrics.Poller.AshOban.Transformer do
  @moduledoc """
  Generates the Oban machinery behind every gauge polled by
  `AshMetrics.Poller.AshOban`.

  For each such gauge it adds two things to the resource:

  * a private generic action `:__ash_metrics_emit_<gauge>__`, run by
    `AshMetrics.Poller.AshOban.Emit`, and
  * an entry in `[:oban, :scheduled_actions]` naming that action, with the
    cron expression for the gauge's `period` and the queue and `max_attempts`
    from `config :ash_metrics, AshMetrics.Poller.AshOban`.

  Resources that use another poller are left alone.

  ## Failures

  Two things can be wrong with such a gauge: the resource may not use the
  `AshOban` extension, leaving no `[:oban, :scheduled_actions]` to add an entry
  to, and the `period` may be one cron cannot express, leaving no entry to add.
  Either is a compile error rather than the warning a verifier would report.
  Both are checked here rather than in a verifier, which would run after every
  transformer.

  It runs before AshOban's own SetDefaults transformer, which resolves a
  scheduled action's queue and checks that the action it names exists;
  everything AshOban generates from the `oban` section runs after that.
  """

  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshMetrics.Config
  alias AshMetrics.Dsl.Gauge
  alias AshMetrics.Poller.AshOban.Cron
  alias AshMetrics.Poller.AshOban.Emit
  alias Spark.Dsl.Transformer
  alias Spark.Error.DslError

  @impl Spark.Dsl.Transformer
  def before?(AshOban.Transformers.SetDefaults), do: true
  def before?(_transformer), do: false

  @impl Spark.Dsl.Transformer
  @spec transform(Spark.Dsl.t()) :: {:ok, Spark.Dsl.t()} | {:error, Exception.t()}
  def transform(dsl_state) do
    case scheduled_gauges(dsl_state) do
      [] -> {:ok, dsl_state}
      gauges -> Enum.reduce_while(gauges, {:ok, dsl_state}, &schedule/2)
    end
  end

  @spec scheduled_gauges(Spark.Dsl.t()) :: [Gauge.t()]
  defp scheduled_gauges(dsl_state) do
    if poller(dsl_state) == AshMetrics.Poller.AshOban do
      dsl_state
      |> Transformer.get_entities([:metrics])
      |> Enum.filter(&match?(%Gauge{}, &1))
    else
      []
    end
  end

  # `AshMetrics.Info.poller/1` answers this for a compiled module, which does
  # not exist yet here, so the option is read from the DSL state instead.
  @spec poller(Spark.Dsl.t()) :: module()
  defp poller(dsl_state) do
    case Transformer.get_option(dsl_state, [:metrics], :poller) do
      nil -> Config.poller()
      poller -> poller
    end
  end

  @spec schedule(Gauge.t(), {:ok, Spark.Dsl.t()}) ::
          {:cont, {:ok, Spark.Dsl.t()}} | {:halt, {:error, Exception.t()}}
  defp schedule(%Gauge{} = gauge, {:ok, dsl_state}) do
    with :ok <- available(dsl_state, gauge),
         {:ok, cron} <- cron(dsl_state, gauge),
         {:ok, dsl_state} <- add_action(dsl_state, gauge),
         {:ok, dsl_state} <- add_schedule(dsl_state, gauge, cron) do
      {:cont, {:ok, dsl_state}}
    else
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  @spec available(Spark.Dsl.t(), Gauge.t()) :: :ok | {:error, Exception.t()}
  defp available(dsl_state, gauge) do
    cond do
      not Code.ensure_loaded?(AshOban) ->
        {:error,
         error(dsl_state, gauge, """
         `AshMetrics.Poller.AshOban` needs the `ash_oban` package, which is \
         not available.

         Add it to your dependencies:

             {:ash_oban, "~> 0.8"}

         or choose another `AshMetrics.Poller` for this resource.
         """)}

      AshOban not in Transformer.get_persisted(dsl_state, :extensions, []) ->
        {:error,
         error(dsl_state, gauge, """
         `AshMetrics.Poller.AshOban` polls a gauge through the resource's own \
         `oban` section, which the `AshOban` extension owns, and this \
         resource does not use it.

         Add it:

             use Ash.Resource,
               extensions: [AshOban, AshMetrics]

         or choose another `AshMetrics.Poller` for this resource.
         """)}

      true ->
        :ok
    end
  end

  @spec cron(Spark.Dsl.t(), Gauge.t()) :: {:ok, String.t()} | {:error, Exception.t()}
  defp cron(dsl_state, %Gauge{} = gauge) do
    case Cron.from_period(gauge.period) do
      {:ok, cron} ->
        {:ok, cron}

      :error ->
        {:error,
         error(dsl_state, gauge, """
         `AshMetrics.Poller.AshOban` schedules a gauge on Oban's cron, which \
         counts in whole minutes, and #{gauge.period}ms is not a period cron \
         can express.

         Use a whole number of minutes from 1 to 59, a whole number of hours \
         from 1 to 23, or exactly one day:

             gauge #{inspect(gauge.name)}, period: :timer.minutes(5)

         Rounding to the nearest expressible period is deliberately not done: \
         a declaration and a schedule that quietly disagree are worse than a \
         compile error. Choose another `AshMetrics.Poller` if this gauge \
         really does need a period cron cannot express.
         """)}
    end
  end

  @spec add_action(Spark.Dsl.t(), Gauge.t()) :: {:ok, Spark.Dsl.t()} | {:error, term()}
  defp add_action(dsl_state, %Gauge{} = gauge) do
    Builder.add_new_action(dsl_state, :action, action_name(gauge),
      run: {Emit, gauge: gauge.name},
      public?: false,
      description:
        "Polls the #{inspect(gauge.name)} gauge. Generated by AshMetrics; " <>
          "call `AshMetrics.Gauge.Runner.emit/3` rather than this."
    )
  end

  @spec add_schedule(Spark.Dsl.t(), Gauge.t(), String.t()) ::
          {:ok, Spark.Dsl.t()} | {:error, term()}
  defp add_schedule(dsl_state, %Gauge{} = gauge, cron) do
    name = action_name(gauge)

    with {:ok, schedule} <-
           Transformer.build_entity(AshOban, [:oban, :scheduled_actions], :schedule,
             name: name,
             action: name,
             cron: cron,
             queue: Config.ash_oban_queue(),
             max_attempts: Config.ash_oban_max_attempts(),
             worker_module_name: worker_module_name(dsl_state, name)
           ) do
      {:ok, Transformer.add_entity(dsl_state, [:oban, :scheduled_actions], schedule)}
    end
  end

  # AshOban warns about a scheduled action with no `worker_module_name`,
  # because renaming one orphans the jobs already enqueued under the old
  # module. The name AshOban would have derived is set explicitly instead.
  @spec worker_module_name(Spark.Dsl.t(), atom()) :: module()
  defp worker_module_name(dsl_state, name) do
    Module.concat([
      Transformer.get_persisted(dsl_state, :module),
      "AshOban",
      "ActionWorker",
      Macro.camelize(to_string(name))
    ])
  end

  # sobelow_skip ["DOS.StringToAtom"]
  @spec action_name(Gauge.t()) :: atom()
  defp action_name(%Gauge{name: name}), do: :"__ash_metrics_emit_#{name}__"

  @spec error(Spark.Dsl.t(), Gauge.t(), String.t()) :: Exception.t()
  defp error(dsl_state, %Gauge{} = gauge, message) do
    DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: [:metrics, :gauge, gauge.name],
      message: message
    )
  end
end
