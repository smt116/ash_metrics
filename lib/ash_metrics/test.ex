defmodule AshMetrics.Test do
  @moduledoc """
  Assertions about the metrics a test emitted.

  `use AshMetrics.Test` after `use ExUnit.Case`. It attaches a handler for
  every metric of the application for the duration of each test, detaches it
  afterwards, and imports `assert_metric_emitted/2`, `refute_metric_emitted/2`
  and `allow/1`.

      defmodule MyApp.MailingsTest do
        use ExUnit.Case, async: true
        use AshMetrics.Test

        test "a delivery emits a sent counter" do
          MyApp.Mailings.deliver!(...)

          assert_metric_emitted "myapp.mailings.templated_delivery.delivery",
            tags: %{status: :sent, provider: "ses"}
        end
      end

  ## Options

  * `:resources` — attach only to the metrics of these resources:

        use AshMetrics.Test, resources: [MyApp.Mailings.TemplatedDelivery]

  * `:shared` — receive every emission, from any process. A module using
    `shared: true` must be `async: false`.

  ## Concurrency

  A test receives an emission only when the emitting process is owned by the
  test process: when that process, or any process in its `$callers`, is the
  test process or a process passed to `allow/1`. `Task`s and other processes
  that propagate `$callers`, such as `Phoenix.LiveViewTest` LiveViews, are
  owned by the process that started them. Modules using these assertions can
  therefore be `async: true`.

  An emission from a process the test does not own is dropped silently. Pass
  that process to `allow/1`, or use `shared: true`.
  """

  @assert_timeout 100
  @refute_timeout 10

  @typedoc "An emission: its measurements and its tags."
  @type emission :: {measurements :: map(), tags :: map()}

  @doc false
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    opts = Keyword.validate!(opts, [:resources, shared: false])

    metrics =
      case Keyword.fetch(opts, :resources) do
        {:ok, resources} -> quote(do: AshMetrics.metrics_for(unquote(resources)))
        :error -> quote(do: AshMetrics.metrics())
      end

    shared = Keyword.fetch!(opts, :shared)

    quote do
      import AshMetrics.Test,
        only: [
          allow: 1,
          assert_metric_emitted: 1,
          assert_metric_emitted: 2,
          refute_metric_emitted: 1,
          refute_metric_emitted: 2
        ]

      setup do
        test_process = self()

        :ok =
          AshMetrics.Backend.Test.attach(unquote(metrics), test_process, shared: unquote(shared))

        on_exit(fn -> AshMetrics.Backend.Test.detach(test_process) end)

        :ok
      end
    end
  end

  @doc """
  Makes the emissions of `pid` count as the calling test's; see
  `AshMetrics.Backend.Test.allow/2`.

  Call it from the test process, before `pid` emits.
  """
  @spec allow(pid()) :: :ok
  def allow(pid), do: AshMetrics.Backend.Test.allow(self(), pid)

  @doc """
  Asserts that a metric named `name` was emitted, and returns its measurements
  and tags.

  `name` is the metric name without its aggregation suffix, as the declaration
  produces it — `"myapp.mailings.templated_delivery.delivery"`, not
  `"...delivery.count"`.

  ## Options

  * `:tags` — tags that must be present, as a map or a keyword list. Matched
    as a subset, so a metric carrying tags this assertion says nothing about
    still matches.
  * `:value` — the expected observed value of a distribution.
  * `:timeout` — how long to wait, in milliseconds. Defaults to
    `#{@assert_timeout}`.

  Emissions of other metrics are left in the mailbox, so several assertions can
  be made in any order.
  """
  @spec assert_metric_emitted(String.t(), keyword()) :: emission()
  def assert_metric_emitted(name, opts \\ []) do
    opts = normalize(opts)

    case await(name, opts, Keyword.get(opts, :timeout, @assert_timeout)) do
      {:ok, emission, others} ->
        restore(others)
        emission

      {:error, others} ->
        restore(others)
        raise ExUnit.AssertionError, message: not_emitted_message(name, opts, others)
    end
  end

  @doc """
  Asserts that no metric named `name` matching `opts` was emitted.

  Takes the same options as `assert_metric_emitted/2`, but waits only
  `#{@refute_timeout}` milliseconds by default: a refutation has to wait out
  its whole timeout every time it succeeds, and an emission that has not
  arrived by then was not emitted synchronously.
  """
  @spec refute_metric_emitted(String.t(), keyword()) :: :ok
  def refute_metric_emitted(name, opts \\ []) do
    opts = normalize(opts)

    case await(name, opts, Keyword.get(opts, :timeout, @refute_timeout)) do
      {:ok, emission, others} ->
        restore(others)
        raise ExUnit.AssertionError, message: emitted_message(name, opts, emission)

      {:error, others} ->
        restore(others)
        :ok
    end
  end

  @spec normalize(keyword()) :: keyword()
  defp normalize(opts) do
    case Keyword.fetch(opts, :tags) do
      {:ok, tags} -> Keyword.put(opts, :tags, AshMetrics.tags!(tags))
      :error -> opts
    end
  end

  @spec await(String.t(), keyword(), timeout()) ::
          {:ok, emission(), [tuple()]} | {:error, [tuple()]}
  defp await(name, opts, timeout) do
    collect(name, opts, System.monotonic_time(:millisecond) + timeout, [])
  end

  @spec collect(String.t(), keyword(), integer(), [tuple()]) ::
          {:ok, emission(), [tuple()]} | {:error, [tuple()]}
  defp collect(name, opts, deadline, others) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ash_metrics, ^name, measurements, tags} = message ->
        if matches?(opts, measurements, tags) do
          {:ok, {measurements, tags}, others}
        else
          collect(name, opts, deadline, [message | others])
        end
    after
      remaining -> {:error, others}
    end
  end

  @spec restore([tuple()]) :: :ok
  defp restore(others) do
    others
    |> Enum.reverse()
    |> Enum.each(&send(self(), &1))
  end

  @spec matches?(keyword(), map(), map()) :: boolean()
  defp matches?(opts, measurements, tags) do
    matches_tags?(opts, tags) and matches_value?(opts, measurements)
  end

  @spec matches_tags?(keyword(), map()) :: boolean()
  defp matches_tags?(opts, tags) do
    opts
    |> Keyword.get(:tags, %{})
    |> Enum.all?(fn {key, value} -> Map.get(tags, key) == value end)
  end

  @spec matches_value?(keyword(), map()) :: boolean()
  defp matches_value?(opts, measurements) do
    case Keyword.fetch(opts, :value) do
      {:ok, value} -> Map.get(measurements, :value) == value
      :error -> true
    end
  end

  @spec not_emitted_message(String.t(), keyword(), [tuple()]) :: String.t()
  defp not_emitted_message(name, opts, others) do
    """
    Expected #{inspect(name)} to be emitted#{expectations(opts)}, but it was not.

    #{describe(name, others)}
    """
  end

  @spec emitted_message(String.t(), keyword(), emission()) :: String.t()
  defp emitted_message(name, opts, {measurements, tags}) do
    """
    Expected #{inspect(name)} not to be emitted#{expectations(opts)}, but it was.

    Measurements: #{inspect(measurements)}
    Tags: #{inspect(tags)}
    """
  end

  @spec expectations(keyword()) :: String.t()
  defp expectations(opts) do
    case Keyword.take(opts, [:tags, :value]) do
      [] -> ""
      expected -> " with " <> Enum.map_join(expected, ", ", fn {k, v} -> "#{k} #{inspect(v)}" end)
    end
  end

  @spec describe(String.t(), [tuple()]) :: String.t()
  defp describe(_name, []), do: "No emission of that name was received."

  defp describe(name, others) do
    emissions =
      others
      |> Enum.reverse()
      |> Enum.map_join("\n", fn {:ash_metrics, ^name, measurements, tags} ->
        "  measurements #{inspect(measurements)}, tags #{inspect(tags)}"
      end)

    "Emissions of that name that were received:\n\n" <> emissions
  end
end
