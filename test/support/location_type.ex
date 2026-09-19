defmodule AshMetrics.Test.LocationType do
  @moduledoc false
  # `AshMetrics.Test.Location` behind an `Ash.Type.NewType`, so that a tag path
  # through a wrapped embedded resource can be exercised.
  use Ash.Type.NewType, subtype_of: AshMetrics.Test.Location
end
