defmodule AshMetrics.Poller.AshOban.CronTest do
  use ExUnit.Case, async: true

  alias AshMetrics.Poller.AshOban.Cron

  doctest Cron

  describe "from_period/1 in minutes" do
    test "maps every minute to the plain expression rather than a step of one" do
      assert Cron.from_period(:timer.minutes(1)) == {:ok, "* * * * *"}
    end

    test "maps a whole number of minutes to a step" do
      assert Cron.from_period(:timer.minutes(2)) == {:ok, "*/2 * * * *"}
      assert Cron.from_period(:timer.minutes(5)) == {:ok, "*/5 * * * *"}
      assert Cron.from_period(:timer.minutes(30)) == {:ok, "*/30 * * * *"}
    end

    test "maps the last minute a step can express" do
      assert Cron.from_period(:timer.minutes(59)) == {:ok, "*/59 * * * *"}
    end
  end

  describe "from_period/1 in hours" do
    test "maps a whole hour rather than sixty minutes" do
      assert Cron.from_period(:timer.minutes(60)) == {:ok, "0 */1 * * *"}
      assert Cron.from_period(:timer.hours(1)) == {:ok, "0 */1 * * *"}
    end

    test "maps a whole number of hours to a step" do
      assert Cron.from_period(:timer.hours(6)) == {:ok, "0 */6 * * *"}
      assert Cron.from_period(:timer.hours(12)) == {:ok, "0 */12 * * *"}
    end

    test "maps the last hour a step can express" do
      assert Cron.from_period(:timer.hours(23)) == {:ok, "0 */23 * * *"}
    end
  end

  describe "from_period/1 in days" do
    test "maps exactly one day to midnight" do
      assert Cron.from_period(:timer.hours(24)) == {:ok, "0 0 * * *"}
      assert Cron.from_period(:timer.minutes(1440)) == {:ok, "0 0 * * *"}
    end
  end

  describe "from_period/1 for a period cron cannot express" do
    test "refuses anything under a minute" do
      assert Cron.from_period(1) == :error
      assert Cron.from_period(:timer.seconds(10)) == :error
      assert Cron.from_period(:timer.seconds(30)) == :error
      assert Cron.from_period(:timer.minutes(1) - 1) == :error
    end

    test "refuses a period that is not a whole number of minutes" do
      assert Cron.from_period(:timer.seconds(90)) == :error
      assert Cron.from_period(:timer.minutes(5) + 1) == :error
    end

    test "refuses a whole number of minutes that no step covers" do
      assert Cron.from_period(:timer.minutes(61)) == :error
      assert Cron.from_period(:timer.minutes(90)) == :error
    end

    test "refuses a whole number of hours that no step covers" do
      assert Cron.from_period(:timer.hours(25)) == :error
      assert Cron.from_period(:timer.hours(36)) == :error
      assert Cron.from_period(:timer.hours(48)) == :error
    end
  end
end
