defmodule S7.Connection.DestructiveRequest do
  @moduledoc false

  alias S7.{Connection, Destructive, Error}
  alias S7.Connection.TransactionCleanup
  alias S7.Protocol.{Job, PDU}

  @type decoder :: (PDU.t() -> :ok | {:error, Error.t()})

  @spec execute(pid(), PDU.t(), Destructive.limits(), atom(), atom(), decoder()) ::
          :ok | {:error, Error.t()}
  def execute(connection, request, limits, operation, stage, decoder)
      when is_function(decoder, 1) do
    with info when is_map(info) <- Connection.info(connection),
         :ok <- Destructive.authorize(info, operation),
         {:ok, token} <-
           Connection.begin_transaction(connection, operation, transaction_options(limits)) do
      dispatch(connection, token, request, operation, stage, decoder)
    end
  end

  defp dispatch(connection, token, request, operation, stage, decoder) do
    case Connection.transaction_request(connection, token, request) do
      {:ok, response} -> decode(connection, token, response, operation, stage, decoder)
      {:error, %Error{} = error} -> abort(connection, token, error, stage)
    end
  end

  defp decode(connection, token, response, operation, stage, decoder) do
    case decoder.(response) do
      :ok ->
        finish(connection, token, operation, stage)

      {:error, %Error{} = error} ->
        if Job.complete_rejection?(error),
          do: TransactionCleanup.release(connection, token, add_outcome(error, :rejected, stage)),
          else: abort(connection, token, error, stage)
    end
  end

  defp finish(connection, token, operation, stage) do
    case Connection.end_transaction(connection, token) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        error = %{error | operation: operation}
        TransactionCleanup.abort(connection, token, add_outcome(error, :completed, stage))
    end
  end

  defp abort(connection, token, error, stage) do
    error =
      case error do
        %Error{reason: :not_connected} -> %{error | layer: :tcp, reason: :connection_closed}
        %Error{} -> error
      end

    TransactionCleanup.abort(connection, token, add_outcome(error, :indeterminate, stage))
  end

  defp transaction_options(limits) do
    [
      timeout: limits.timeout,
      step_timeout: limits.step_timeout,
      maximum_messages: 2,
      maximum_bytes: 1024,
      inbox_limit: 1
    ]
  end

  defp add_outcome(error, outcome, stage) do
    details = error.details |> Map.put(:outcome, outcome) |> Map.put(:stage, stage)
    %{error | details: details}
  end
end
