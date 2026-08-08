defmodule S7.Test.Fixture do
  @moduledoc false

  def read!(path) do
    Path.join([__DIR__, "..", "fixtures", path])
    |> Path.expand()
    |> File.read!()
  end
end
