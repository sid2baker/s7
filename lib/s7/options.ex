defmodule S7.Options do
  @moduledoc false

  alias S7.Error

  @spec validate_keys(term(), [atom()], atom()) :: :ok | {:error, Error.t()}
  def validate_keys(opts, allowed, operation) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Enum.find(Keyword.keys(opts), &(&1 not in allowed)) do
        nil ->
          :ok

        option ->
          {:error,
           Error.new(:client, operation, :invalid_option,
             details: %{option: option, value: Keyword.get(opts, option)}
           )}
      end
    else
      invalid_options(opts, operation)
    end
  end

  def validate_keys(opts, _allowed, operation), do: invalid_options(opts, operation)

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

  defp invalid_options(opts, operation),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}
end
