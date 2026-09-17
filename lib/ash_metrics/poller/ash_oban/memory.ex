defmodule AshMetrics.Poller.AshOban.Memory do
  @moduledoc """
  Remembers which groups a gauge polled by Oban last found.

  `AshMetrics.Gauge.Runner` zeroes a group that the previous poll found and
  this one did not, so something has to hold those groups between polls.
  `AshMetrics.Poller.GenServer` keeps them in its own process state; an Oban
  job has no state between runs, and this module is the substitute for it.

  ## What this does not promise

  The record is per node and best effort. Oban's crontab is a cluster-wide
  singleton, so whichever node's queue picks a job up runs it, and a node
  knows only about the groups it happened to poll itself.

  A group that vanishes is therefore zeroed by each node that had seen it, the
  next time that node runs the job — not at the moment it vanished, and not by
  a node that has never run this gauge's poll. A freshly started node zeroes
  nothing, and the record does not survive a restart. A gauge whose groups come
  and go constantly is better served by `AshMetrics.Poller.GenServer`, where
  every node polls and every node remembers.
  """

  @doc """
  The groups the last poll of `gauge_name` on `resource` found.

  Returns `[]` when this node has never polled it.
  """
  @spec get(module(), atom()) :: [AshMetrics.tags()]
  def get(resource, gauge_name), do: :persistent_term.get(key(resource, gauge_name), [])

  @doc """
  Remembers `groups` as what the last poll of `gauge_name` on `resource`
  found.

  Call it only after a successful poll; a failed poll says nothing about which
  groups still exist.
  """
  @spec put(module(), atom(), [AshMetrics.tags()]) :: :ok
  def put(resource, gauge_name, groups) do
    :persistent_term.put(key(resource, gauge_name), groups)
  end

  @doc """
  Forgets everything known about `gauge_name` on `resource`.

  Nothing in the package calls this. It is available to tests, and to an
  application that wants a deployment to start from silence rather than zero a
  group it no longer publishes.
  """
  @spec clear(module(), atom()) :: :ok
  def clear(resource, gauge_name) do
    :persistent_term.erase(key(resource, gauge_name))

    :ok
  end

  @spec key(module(), atom()) :: {module(), module(), atom()}
  defp key(resource, gauge_name), do: {__MODULE__, resource, gauge_name}
end
