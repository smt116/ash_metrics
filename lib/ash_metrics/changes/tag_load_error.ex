defmodule AshMetrics.Changes.TagLoadError do
  @moduledoc """
  The error the call that opened a transaction returns when the calculations
  or aggregates a metric's tags name fail to load while that transaction is
  open. See `AshMetrics.Changes.IncrementOnChange`, "Transactions".

  Its fields are the `resource`, the `action` name, the `metric` name, the
  `fields` the change loaded and the `error` the load failed with: the Ash
  error class holding the data layer's errors when the data layer rejected
  the load, the exception the load raised, or `{kind, reason}` for any other
  throw or an exit. Its class is `:unknown`, so Ash returns it inside an
  `Ash.Error.Unknown`.
  """

  use Splode.Error, fields: [:resource, :action, :metric, :fields, :error], class: :unknown

  @type t :: %__MODULE__{
          resource: module(),
          action: atom(),
          metric: atom(),
          fields: [atom()],
          error: Exception.t() | {:throw | :exit, term()}
        }

  @impl Exception
  def message(error) do
    "AshMetrics could not load #{inspect(error.fields)} for the tags of " <>
      "#{inspect(error.metric)} on #{inspect(error.resource)} from action " <>
      "#{inspect(error.action)}: #{reason(error.error)}"
  end

  @spec reason(Exception.t() | {:throw | :exit, term()}) :: String.t()
  defp reason({kind, reason}), do: Exception.format_banner(kind, reason)
  defp reason(exception), do: Exception.message(exception)
end
