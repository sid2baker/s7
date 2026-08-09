defmodule S7.Connection.BlockDownloader do
  @moduledoc false

  alias S7.{Block, BlockImage, Connection, Destructive, Error}
  alias S7.Connection.TransactionCleanup
  alias S7.Protocol.{BlockDownload, PIService}

  @maximum_fragments 4096
  @download_response_overhead 18

  @spec download(pid(), BlockImage.t(), Destructive.limits(), atom()) ::
          :ok | {:error, Error.t()}
  def download(connection, image, limits, operation) do
    with info when is_map(info) <- Connection.info(connection),
         :ok <- Destructive.authorize(info, operation),
         {:ok, request, transaction} <- BlockDownload.start_request(image, operation),
         {:ok, fragment_count} <- planned_fragments(image.raw, info.pdu_size, operation),
         {:ok, token} <-
           Connection.begin_transaction(
             connection,
             operation,
             transaction_options(image.raw, fragment_count, limits)
           ) do
      execute_download(connection, token, request, transaction, info.pdu_size, limits)
    end
  end

  @spec delete(pid(), Block.t(), Destructive.limits(), atom()) :: :ok | {:error, Error.t()}
  def delete(connection, block, limits, operation) do
    with info when is_map(info) <- Connection.info(connection),
         :ok <- Destructive.authorize(info, operation),
         {:ok, request} <- PIService.block_request(block, :delete, operation),
         {:ok, token} <-
           Connection.begin_transaction(connection, operation, simple_transaction_options(limits)) do
      execute_pi_service(connection, token, request, operation, :delete)
    end
  end

  defp execute_download(connection, token, request, transaction, pdu_size, limits) do
    case Connection.transaction_request(connection, token, request) do
      {:ok, response} ->
        consume_start(connection, token, response, transaction, pdu_size, limits)

      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, indeterminate(error, :request_download))
    end
  end

  defp consume_start(connection, token, response, transaction, pdu_size, limits) do
    case BlockDownload.consume_start(response, transaction) do
      {:ok, transaction} ->
        receive_download_job(connection, token, transaction, pdu_size, limits)

      {:error, %Error{} = error} ->
        if BlockDownload.complete_rejection?(error) do
          TransactionCleanup.release(
            connection,
            token,
            add_outcome(error, :rejected, :request_download)
          )
        else
          TransactionCleanup.abort(connection, token, indeterminate(error, :request_download))
        end
    end
  end

  defp receive_download_job(connection, token, transaction, pdu_size, limits) do
    case Connection.transaction_receive(connection, token, limits.step_timeout) do
      {:ok, request} ->
        consume_download_job(connection, token, request, transaction, pdu_size, limits)

      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, indeterminate(error, transaction.stage))
    end
  end

  defp consume_download_job(connection, token, request, transaction, pdu_size, limits) do
    case transaction.stage do
      :download ->
        reply_download_block(connection, token, request, transaction, pdu_size, limits)

      :download_ended ->
        reply_download_end(connection, token, request, transaction)
    end
  end

  defp reply_download_block(connection, token, request, transaction, pdu_size, limits) do
    with {:ok, response, transaction} <-
           BlockDownload.consume_download_job(request, transaction, pdu_size),
         :ok <- Connection.transaction_reply(connection, token, response) do
      receive_download_job(connection, token, transaction, pdu_size, limits)
    else
      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, indeterminate(error, :download_block))
    end
  end

  defp reply_download_end(connection, token, request, transaction) do
    with {:ok, response, transaction, end_request} <-
           BlockDownload.consume_end_job(request, transaction),
         :ok <- Connection.transaction_reply(connection, token, response) do
      finish_download_end(connection, token, transaction, end_request)
    else
      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, indeterminate(error, :download_ended))
    end
  end

  defp finish_download_end(connection, token, transaction, end_request) do
    case BlockDownload.end_error(end_request, transaction.operation) do
      :ok ->
        activate_block(connection, token, transaction)

      {:error, %Error{} = error} ->
        TransactionCleanup.release(
          connection,
          token,
          add_outcome(error, :rejected, :download_ended)
        )
    end
  end

  defp activate_block(connection, token, transaction) do
    with {:ok, request} <-
           PIService.block_request(transaction.block, :insert, transaction.operation),
         {:ok, response} <- Connection.transaction_request(connection, token, request) do
      finish_activation(connection, token, response, transaction.operation)
    else
      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, indeterminate(error, :activate_block))
    end
  end

  defp finish_activation(connection, token, response, operation) do
    case PIService.decode_response(response, operation) do
      :ok ->
        finish_success(connection, token)

      {:error, %Error{} = error} ->
        if PIService.complete_rejection?(error) do
          error = add_outcome(error, :downloaded_not_activated, :activate_block)
          TransactionCleanup.release(connection, token, error)
        else
          TransactionCleanup.abort(connection, token, indeterminate(error, :activate_block))
        end
    end
  end

  defp execute_pi_service(connection, token, request, operation, stage) do
    case Connection.transaction_request(connection, token, request) do
      {:ok, response} ->
        finish_pi_service(connection, token, response, operation, stage)

      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, indeterminate(error, stage))
    end
  end

  defp finish_pi_service(connection, token, response, operation, stage) do
    case PIService.decode_response(response, operation) do
      :ok ->
        finish_success(connection, token)

      {:error, %Error{} = error} ->
        if PIService.complete_rejection?(error),
          do:
            TransactionCleanup.release(
              connection,
              token,
              add_outcome(error, :rejected, stage)
            ),
          else: TransactionCleanup.abort(connection, token, indeterminate(error, stage))
    end
  end

  defp finish_success(connection, token) do
    case Connection.end_transaction(connection, token) do
      :ok -> :ok
      {:error, %Error{} = error} -> TransactionCleanup.abort(connection, token, error)
    end
  end

  defp planned_fragments(image, pdu_size, operation)
       when is_binary(image) and is_integer(pdu_size) and pdu_size > @download_response_overhead do
    slice_size = pdu_size - @download_response_overhead
    fragment_count = div(byte_size(image) + slice_size - 1, slice_size)

    if fragment_count <= @maximum_fragments do
      {:ok, fragment_count}
    else
      {:error,
       Error.new(:client, operation, :too_many_download_fragments,
         details: %{fragment_count: fragment_count, limit: @maximum_fragments}
       )}
    end
  end

  defp planned_fragments(_image, pdu_size, operation),
    do: {:error, Error.new(:s7, operation, :pdu_too_small, details: %{pdu_size: pdu_size})}

  defp transaction_options(image, fragment_count, limits) do
    [
      timeout: limits.timeout,
      step_timeout: limits.step_timeout,
      maximum_messages: fragment_count * 2 + 6,
      maximum_bytes: byte_size(image) + fragment_count * 64 + 1024,
      inbox_limit: 1
    ]
  end

  defp simple_transaction_options(limits) do
    [
      timeout: limits.timeout,
      step_timeout: limits.step_timeout,
      maximum_messages: 2,
      maximum_bytes: 1024,
      inbox_limit: 1
    ]
  end

  defp indeterminate(%Error{reason: :not_connected} = error, stage) do
    error = %{error | layer: :tcp, reason: :connection_closed}
    add_outcome(error, :indeterminate, stage)
  end

  defp indeterminate(error, stage), do: add_outcome(error, :indeterminate, stage)

  defp add_outcome(error, outcome, stage) do
    details = error.details |> Map.put(:outcome, outcome) |> Map.put(:stage, stage)
    %{error | details: details}
  end
end
