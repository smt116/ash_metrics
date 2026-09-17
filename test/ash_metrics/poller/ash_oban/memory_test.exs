defmodule AshMetrics.Poller.AshOban.MemoryTest do
  # `:persistent_term` is global, so it cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias AshMetrics.Poller.AshOban.Memory
  alias AshMetrics.Test.Job
  alias AshMetrics.Test.ObanJob

  setup do
    clear()
    on_exit(&clear/0)
  end

  describe "get/2" do
    test "remembers nothing before the first poll" do
      assert Memory.get(ObanJob, :backlog) == []
    end

    test "returns what was last put" do
      groups = [%{status: :pending}, %{status: :processing}]

      assert Memory.put(ObanJob, :backlog, groups) == :ok
      assert Memory.get(ObanJob, :backlog) == groups
    end

    test "keeps one memory per gauge" do
      Memory.put(ObanJob, :backlog, [%{status: :pending}])

      assert Memory.get(ObanJob, :total) == []
    end

    test "keeps one memory per resource" do
      Memory.put(ObanJob, :backlog, [%{status: :pending}])

      assert Memory.get(Job, :backlog) == []
    end
  end

  describe "put/3" do
    test "replaces what was remembered rather than adding to it" do
      Memory.put(ObanJob, :backlog, [%{status: :pending}])
      Memory.put(ObanJob, :backlog, [%{status: :processing}])

      assert Memory.get(ObanJob, :backlog) == [%{status: :processing}]
    end

    test "remembers that a gauge found no groups at all" do
      Memory.put(ObanJob, :backlog, [%{status: :pending}])
      Memory.put(ObanJob, :backlog, [])

      assert Memory.get(ObanJob, :backlog) == []
    end
  end

  describe "clear/2" do
    test "forgets what was remembered" do
      Memory.put(ObanJob, :backlog, [%{status: :pending}])

      assert Memory.clear(ObanJob, :backlog) == :ok
      assert Memory.get(ObanJob, :backlog) == []
    end

    test "forgets nothing it was never told" do
      assert Memory.clear(ObanJob, :never_polled) == :ok
    end
  end

  defp clear do
    Memory.clear(ObanJob, :backlog)
    Memory.clear(ObanJob, :total)
    Memory.clear(Job, :backlog)

    :ok
  end
end
