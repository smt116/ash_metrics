defmodule AshMetrics.Poller.AshOban.Cron do
  @moduledoc """
  Turns a gauge's `period` into the cron expression Oban schedules it with.

  A period is milliseconds and a cron expression is whole minutes. Only
  periods that cron can express exactly are accepted, and no period is
  rounded:

  * a whole number of minutes from one to fifty-nine, as `*/N * * * *`
  * a whole number of hours from one to twenty-three, as `0 */H * * *`
  * exactly one day, as `0 0 * * *`

  Anything else — thirty seconds, ninety seconds, twenty-five hours — returns
  `:error`, and `AshMetrics.Poller.AshOban.Transformer` turns that into a
  `Spark.Error.DslError` naming the gauge.

  The step syntax fires at fixed points of the hour or day: `*/20 * * * *`
  fires at minute 0, 20 and 40 of every hour, so the last interval of an hour
  that does not divide evenly is shorter than the period asks for.
  `0 */7 * * *` behaves the same way across a day. Prefer a period that divides
  its unit evenly.

      iex> AshMetrics.Poller.AshOban.Cron.from_period(:timer.minutes(5))
      {:ok, "*/5 * * * *"}

      iex> AshMetrics.Poller.AshOban.Cron.from_period(:timer.hours(6))
      {:ok, "0 */6 * * *"}

      iex> AshMetrics.Poller.AshOban.Cron.from_period(:timer.seconds(90))
      :error
  """

  @minute 60_000
  @hour 60 * @minute
  @day 24 * @hour

  @doc """
  The cron expression that fires every `period` milliseconds.

  Returns `{:ok, expression}` for a period cron can express exactly, and
  `:error` for one it cannot.
  """
  @spec from_period(pos_integer()) :: {:ok, String.t()} | :error
  def from_period(@day), do: {:ok, "0 0 * * *"}

  def from_period(period) when is_integer(period) and period > 0 do
    cond do
      period < @minute -> :error
      rem(period, @hour) == 0 -> hourly(div(period, @hour))
      rem(period, @minute) == 0 -> minutely(div(period, @minute))
      true -> :error
    end
  end

  @spec minutely(pos_integer()) :: {:ok, String.t()} | :error
  defp minutely(1), do: {:ok, "* * * * *"}
  defp minutely(minutes) when minutes <= 59, do: {:ok, "*/#{minutes} * * * *"}
  defp minutely(_minutes), do: :error

  @spec hourly(pos_integer()) :: {:ok, String.t()} | :error
  defp hourly(hours) when hours <= 23, do: {:ok, "0 */#{hours} * * *"}
  defp hourly(_hours), do: :error
end
