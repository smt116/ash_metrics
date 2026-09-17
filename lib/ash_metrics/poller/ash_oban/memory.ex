defmodule AshMetrics.Poller.AshOban.Memory do
  @moduledoc """
  Remembers which groups a gauge polled by Oban last found.

  A `last_value` metric keeps reporting the last number it was given, so a
  gauge grouped by status that drains from `%{status: :pending} => 12` to
  nothing would sit at 12 forever. `AshMetrics.Gauge.Runner` avoids that by
  emitting a single zero for every group the previous poll found and this one
  did not — which means something has to hold "the groups the previous poll
  found" between polls.

  `AshMetrics.Poller.GenServer` keeps that in its own process state. An Oban
  job has no state at all: it is a fresh process, usually on a different node
  than the last one. This module is the substitute.

  ## Why `:persistent_term`

  It has no owner process, so nothing has to be started, supervised or
  restarted, and a value survives every job process that reads it. The usual
  objection — that writing to it is expensive, because it triggers a global GC
  scan of the term being replaced — does not bite here: a gauge writes once per
  poll, and a poll happens at most once a minute.

  ## What this does not promise

  It is per node and best effort, and the crontab that drives it is a
  singleton: Oban inserts one job per schedule for the whole cluster, and
  whichever node's queue picks it up runs it. So a node only knows about the
  groups it happened to run the poll for.

  In practice, a group that vanishes is zeroed by each node that had seen it,
  the next time that node runs the job — not at the moment it vanished, and
  not by a node that has never run this gauge's poll. A freshly started node
  zeroes nothing at all, because it remembers nothing. That is the trade for
  keeping the state out of the database; a gauge whose groups come and go
  constantly is better served by the timer poller, where every node polls and
  every node remembers.

  The memory is not persisted across a restart either, which is the same
  statement about a fresh node said differently.
  """

  @doc """
  The groups the last poll of `gauge_name` on `resource` found.

  Returns `[]` when this node has never polled it, which is what makes a
  first poll after a restart zero nothing.
  """
  @spec get(module(), atom()) :: [AshMetrics.tags()]
  def get(resource, gauge_name), do: :persistent_term.get(key(resource, gauge_name), [])

  @doc """
  Remembers `groups` as what the last poll of `gauge_name` on `resource`
  found.

  Call it only after a successful poll: a failed one says nothing about which
  groups still exist, and forgetting what it knew would lose a zero.
  """
  @spec put(module(), atom(), [AshMetrics.tags()]) :: :ok
  def put(resource, gauge_name, groups) do
    :persistent_term.put(key(resource, gauge_name), groups)
  end

  @doc """
  Forgets everything known about `gauge_name` on `resource`.

  Nothing in the package calls this; it is here for tests, and for an
  application that wants a deployment to start from silence rather than zero
  a group it no longer publishes.
  """
  @spec clear(module(), atom()) :: :ok
  def clear(resource, gauge_name) do
    :persistent_term.erase(key(resource, gauge_name))

    :ok
  end

  @spec key(module(), atom()) :: {module(), module(), atom()}
  defp key(resource, gauge_name), do: {__MODULE__, resource, gauge_name}
end
