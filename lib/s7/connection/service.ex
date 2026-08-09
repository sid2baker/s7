defmodule S7.Connection.Service do
  @moduledoc false

  alias S7.Error

  @spec validate_options(term(), [atom()], atom()) :: :ok | {:error, Error.t()}
  def validate_options(opts, allowed, operation) when is_list(opts) and is_list(allowed) do
    cond do
      not Keyword.keyword?(opts) ->
        client_error(operation, :invalid_options, %{options: opts})

      option = Enum.find(Keyword.keys(opts), &(&1 not in allowed)) ->
        client_error(operation, :invalid_option, %{
          option: option,
          value: Keyword.get(opts, option)
        })

      true ->
        :ok
    end
  end

  def validate_options(opts, _allowed, operation),
    do: client_error(operation, :invalid_options, %{options: opts})

  @spec positive_option(keyword(), atom(), pos_integer(), atom()) ::
          {:ok, pos_integer()} | {:error, Error.t()}
  def positive_option(opts, key, default, operation) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: client_error(operation, :invalid_option, %{option: key, value: value})
  end

  @spec transaction_options(%{timeout: pos_integer(), step_timeout: pos_integer()}) :: keyword()
  def transaction_options(options) do
    [
      timeout: options.timeout,
      step_timeout: options.step_timeout,
      maximum_messages: 2,
      maximum_bytes: 131_072,
      inbox_limit: 1
    ]
  end

  @spec normalize_error(Error.t(), atom()) :: Error.t()
  def normalize_error(%Error{} = error, operation), do: %{error | operation: operation}

  @spec client_error(atom(), atom(), map()) :: {:error, Error.t()}
  def client_error(operation, reason, details \\ %{}),
    do: {:error, Error.new(:client, operation, reason, details: details)}
end
