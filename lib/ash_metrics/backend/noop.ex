defmodule AshMetrics.Backend.Noop do
  @moduledoc """
  A backend that starts nothing. The default.

  Use it when the host application already runs a reporter and only splices
  `AshMetrics.metrics/0` into that reporter's own metric list, or in
  development, where nothing is collecting.
  """

  @behaviour AshMetrics.Backend

  @impl AshMetrics.Backend
  @spec child_spec(keyword()) :: :ignore
  def child_spec(_opts), do: :ignore
end
