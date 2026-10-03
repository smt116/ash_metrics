defmodule AshMetrics.Changes.IncrementOnChangeTest.Failing do
  @moduledoc false
  # A tag extractor that raises on every emission.

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  def tag_keys, do: [:tenant]

  @impl AshMetrics.TagExtractor
  def extract(_metadata), do: raise("extractor exploded")
end

defmodule AshMetrics.Changes.IncrementOnChangeTest.Throwing do
  @moduledoc false
  # A tag extractor that throws on every emission.

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  def tag_keys, do: [:tenant]

  @impl AshMetrics.TagExtractor
  def extract(_metadata), do: throw(:extractor_thrown)
end

defmodule AshMetrics.Changes.IncrementOnChangeTest.Exiting do
  @moduledoc false
  # A tag extractor that exits on every emission.

  @behaviour AshMetrics.TagExtractor

  @impl AshMetrics.TagExtractor
  def tag_keys, do: [:tenant]

  @impl AshMetrics.TagExtractor
  def extract(_metadata), do: exit(:extractor_exited)
end

defmodule AshMetrics.Changes.IncrementOnChangeTest.Unregistered do
  @moduledoc false
  # The domain the resources compiled by a test are run through.
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshMetrics.Changes.IncrementOnChangeTest do
  # Seeds an ETS table the whole node shares, so it cannot run alongside other
  # tests.
  use ExUnit.Case, async: false
  use AshMetrics.Test, resources: [AshMetrics.Test.Ticket]

  import ExUnit.CaptureLog

  alias AshMetrics.Test.Compiler
  alias AshMetrics.Test.Ets
  alias AshMetrics.Test.Ticket

  @metric "test.queue.ticket.transitions"

  setup do
    Ets.clear!()
    on_exit(&Ets.clear!/0)

    :ok
  end

  test "a create emits the value it wrote, with the record's other tags" do
    open!(priority: :high, assignee: "ana")

    assert {%{count: 1}, tags} = assert_metric_emitted(@metric)
    assert tags == %{status: :open, priority: :high, assignee: "ana"}
  end

  test "an update to a new value emits it" do
    ticket = open!(priority: :low, assignee: "ana")

    Ash.update!(ticket, %{status: :resolved}, action: :update_status)

    assert_metric_emitted(@metric, tags: %{status: :resolved, priority: :low})
  end

  test "a destroy writing a new value emits it, with the record's other tags" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    assert :ok = Ash.destroy(ticket, action: :close_out)

    assert {%{count: 1}, tags} = assert_metric_emitted(@metric)
    assert tags == %{status: :closed, priority: :low, assignee: "ana"}
  end

  test "an update that leaves the attribute alone emits nothing" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    Ash.update!(ticket, %{assignee: "bo"}, action: :rename)

    refute_metric_emitted(@metric)
  end

  test "an update writing the same value again emits nothing" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    Ash.update!(ticket, %{status: :open}, action: :update_status)

    refute_metric_emitted(@metric)
  end

  test "a failed action emits nothing" do
    ticket = open!(priority: :low, assignee: "ana")
    assert_metric_emitted(@metric, tags: %{status: :open})

    assert {:error, _error} = Ash.update(ticket, %{status: :nope}, action: :update_status)

    refute_metric_emitted(@metric)
  end

  test "the tag extractor reads the changeset's context" do
    ticket = open!(priority: :low, assignee: "ana")

    ticket
    |> Ash.Changeset.for_update(:update_status, %{status: :in_progress},
      context: %{tenant: "acme"}
    )
    |> Ash.update!()

    assert_metric_emitted(@metric, tags: %{status: :in_progress, tenant: "acme"})
  end

  test "a rejected emission is logged and leaves the action's result alone" do
    log =
      capture_log(fn ->
        assert %Ticket{priority: nil} = open!(assignee: "ana")
      end)

    assert log =~ "AshMetrics did not emit :transitions on AshMetrics.Test.Ticket"
    assert log =~ "from action :open"
    assert log =~ ":priority is a required tag"

    refute_metric_emitted(@metric)
  end

  test "any exception raised while emitting is logged and leaves the action's result alone" do
    log = failed_open_log(__MODULE__.Failing)

    assert log =~ "AshMetrics did not emit :transitions on AshMetrics.Test.Ticket"
    assert log =~ "from action :open"
    assert log =~ "extractor exploded"

    refute_metric_emitted(@metric)
  end

  test "a throw while emitting is logged and leaves the action's result alone" do
    log = failed_open_log(__MODULE__.Throwing)

    assert log =~ "AshMetrics did not emit :transitions on AshMetrics.Test.Ticket"
    assert log =~ "** (throw) :extractor_thrown"

    refute_metric_emitted(@metric)
  end

  test "an exit while emitting is logged and leaves the action's result alone" do
    log = failed_open_log(__MODULE__.Exiting)

    assert log =~ "AshMetrics did not emit :transitions on AshMetrics.Test.Ticket"
    assert log =~ "** (exit) :extractor_exited"

    refute_metric_emitted(@metric)
  end

  test "a declaration the verifier rejects leaves a union tag off and carries a tuple whole" do
    resource =
      Compiler.compile_resource(
        quote do
          metrics do
            counter :writes, tags: [:status, :choice, :pair]
          end
        end,
        [
          quote(do: attribute(:status, :atom, public?: true)),
          quote do
            attribute :choice, :union,
              public?: true,
              constraints: [types: [name: [type: :string], size: [type: :integer]]]
          end,
          quote do
            attribute :pair, :tuple,
              public?: true,
              constraints: [fields: [a: [type: :string], b: [type: :integer]]]
          end
        ],
        [
          quote do
            actions do
              create :write do
                accept [:status, :choice, :pair]

                change AshMetrics.increment_on_change(:writes, :status)
              end
            end
          end
        ],
        Ash.DataLayer.Ets
      )

    # The verifier reports the first tag it rejects, `:choice`; its rejection
    # of `:pair` is pinned in `AshMetrics.Verifiers.VerifyMetricsTest`.
    assert [error] = Compiler.dsl_errors_for(resource)
    assert Exception.message(error) =~ "declares the tag :choice"
    assert Exception.message(error) =~ "Ash.Type.Union"

    # A resource with no domain has no metric name to assert on, so the
    # handler listens for its event.
    test_process = self()
    handler = {__MODULE__, test_process}

    :ok =
      :telemetry.attach(
        handler,
        AshMetrics.event_name(resource, :writes),
        fn _event, measurements, metadata, _config ->
          send(test_process, {:emitted, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    resource
    |> Ash.Changeset.for_create(:write, %{status: :written, choice: "ana", pair: {"ana", 1}},
      domain: __MODULE__.Unregistered
    )
    |> Ash.create!()

    assert_receive {:emitted, %{count: 1}, metadata}
    assert %{status: :written, pair: {"ana", 1}} = metadata
    refute Map.has_key?(metadata, :choice)
  end

  # Opens a ticket with `extractor` as the tag extractor, asserts the action
  # still succeeds, and returns what it logged.
  defp failed_open_log(extractor) do
    original = Application.get_env(:ash_metrics, :tag_extractor)
    Application.put_env(:ash_metrics, :tag_extractor, extractor)

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:ash_metrics, :tag_extractor)
        extractor -> Application.put_env(:ash_metrics, :tag_extractor, extractor)
      end
    end)

    capture_log(fn ->
      assert %Ticket{status: :open} = open!(priority: :low, assignee: "ana")
    end)
  end

  defp open!(attrs), do: Ash.create!(Ticket, Map.new(attrs), action: :open)
end
