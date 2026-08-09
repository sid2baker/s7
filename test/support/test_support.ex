defmodule S7.TestSupport do
  @moduledoc false

  def info!(client) do
    case S7.info(client) do
      {:ok, info} -> info
      {:error, error} -> raise error
    end
  end
end
