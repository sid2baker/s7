defmodule S7.Options do
  @moduledoc false

  alias S7.Error

  @spec positive(keyword(), atom(), term(), pos_integer(), atom()) ::
          {:ok, pos_integer()} | {:error, Error.t()}
  def positive(opts, key, default, maximum, operation) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 and value <= maximum do
      {:ok, value}
    else
      {:error,
       Error.new(:client, operation, :invalid_option, details: %{option: key, value: value})}
    end
  end
end
