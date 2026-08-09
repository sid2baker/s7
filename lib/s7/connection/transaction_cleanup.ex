defmodule S7.Connection.TransactionCleanup do
  @moduledoc false

  alias S7.{Connection, Error}

  @spec release(pid(), reference(), Error.t()) :: {:error, Error.t()}
  def release(connection, token, error) do
    case Connection.end_transaction(connection, token) do
      :ok -> {:error, error}
      {:error, %Error{reason: :not_connected}} -> {:error, error}
      {:error, %Error{}} -> abort(connection, token, error)
    end
  end

  @spec abort(pid(), reference(), Error.t()) :: {:error, Error.t()}
  def abort(connection, token, error) do
    case Connection.abort_transaction(connection, token, error) do
      :ok ->
        {:error, error}

      {:error, %Error{} = abort_error} ->
        {:error,
         %{
           error
           | details:
               Map.put_new(error.details, :cleanup, %{
                 layer: abort_error.layer,
                 reason: abort_error.reason,
                 code: abort_error.code
               })
         }}
    end
  end
end
