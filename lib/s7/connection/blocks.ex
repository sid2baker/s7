defmodule S7.Connection.Blocks do
  @moduledoc false

  alias S7.{Block, Connection, Destructive, Error}
  alias S7.Connection.{DestructiveRequest, TransactionCleanup}
  alias S7.Protocol.{BlockDownload, BlockUpload, PIService}

  @maximum_download_fragments 4096
  @download_response_overhead 18

  @spec validate_upload_options(term(), atom()) ::
          {:ok, BlockUpload.limits()} | {:error, Error.t()}
  def validate_upload_options(opts, operation), do: BlockUpload.validate_options(opts, operation)

  @spec upload(pid(), Block.t(), BlockUpload.limits(), boolean(), atom()) ::
          {:ok, Block.Image.t() | binary()} | {:error, Error.t()}
  def upload(connection, block, limits, raw?, operation) do
    with {:ok, start_request, transaction} <-
           BlockUpload.start_request(block, limits, operation),
         {:ok, token} <-
           Connection.begin_transaction(connection, operation, transaction_options(limits)) do
      execute(connection, token, start_request, transaction, raw?)
    end
  end

  defp execute(connection, token, start_request, transaction, raw?) do
    case Connection.transaction_request(connection, token, start_request) do
      {:ok, response} -> consume_start(connection, token, response, transaction, raw?)
      {:error, %Error{} = error} -> release_after_unsent_start(connection, token, error)
    end
  end

  defp consume_start(connection, token, response, transaction, raw?) do
    case BlockUpload.consume_start(response, transaction) do
      {:ok, transaction} ->
        start_segments(connection, token, transaction, raw?)

      {:error, %Error{} = error} ->
        if BlockUpload.initial_rejection?(error) do
          release_after_unsent_start(connection, token, error)
        else
          TransactionCleanup.abort(connection, token, error)
        end
    end
  end

  defp start_segments(connection, token, transaction, raw?) do
    case BlockUpload.validate_advertised_size(transaction) do
      :ok -> request_segment(connection, token, transaction, raw?)
      {:error, %Error{} = error} -> finish_bounded_failure(connection, token, transaction, error)
    end
  end

  defp request_segment(connection, token, transaction, raw?) do
    with {:ok, request} <- BlockUpload.upload_request(transaction),
         {:ok, response} <- Connection.transaction_request(connection, token, request) do
      consume_segment(connection, token, response, transaction, raw?)
    else
      {:error, %Error{} = error} -> TransactionCleanup.abort(connection, token, error)
    end
  end

  defp consume_segment(connection, token, response, transaction, raw?) do
    case BlockUpload.consume_segment(response, transaction) do
      {:continue, transaction} ->
        request_segment(connection, token, transaction, raw?)

      {:complete, raw, transaction} ->
        finish_success(connection, token, transaction, raw, raw?)

      {:error, %Error{} = error} ->
        if BlockUpload.local_limit_error?(error) do
          finish_bounded_failure(connection, token, transaction, error)
        else
          TransactionCleanup.abort(connection, token, error)
        end
    end
  end

  defp finish_success(connection, token, transaction, raw, raw?) do
    case finish_remote(connection, token, transaction) do
      :ok when raw? -> {:ok, raw}
      :ok -> Block.Image.decode(raw, transaction.block, transaction.operation)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp finish_bounded_failure(connection, token, transaction, error) do
    case finish_remote(connection, token, transaction) do
      :ok ->
        {:error, error}

      {:error, %Error{} = cleanup_error} ->
        {:error,
         %{
           error
           | details:
               Map.put(error.details, :cleanup, %{
                 layer: cleanup_error.layer,
                 reason: cleanup_error.reason,
                 code: cleanup_error.code
               })
         }}
    end
  end

  defp finish_remote(connection, token, transaction) do
    with {:ok, request} <- BlockUpload.end_request(transaction),
         {:ok, response} <- Connection.transaction_request(connection, token, request),
         :ok <- BlockUpload.consume_end(response, transaction),
         :ok <- Connection.end_transaction(connection, token) do
      :ok
    else
      {:error, %Error{} = error} -> TransactionCleanup.abort(connection, token, error)
    end
  end

  defp release_after_unsent_start(connection, token, error) do
    TransactionCleanup.release(connection, token, error)
  end

  defp transaction_options(limits) do
    options = [
      timeout: limits.timeout,
      maximum_messages: limits.max_fragments * 2 + 4,
      maximum_bytes: limits.max_bytes + limits.max_fragments * 64 + 1024,
      inbox_limit: 1
    ]

    if limits.step_timeout do
      Keyword.put(options, :step_timeout, limits.step_timeout)
    else
      options
    end
  end

  @spec download(pid(), Block.Image.t(), Destructive.limits(), atom()) ::
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
    with {:ok, request} <- PIService.block_request(block, :delete, operation) do
      DestructiveRequest.execute(
        connection,
        request,
        limits,
        operation,
        :delete,
        &PIService.decode_response(&1, operation)
      )
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

    if fragment_count <= @maximum_download_fragments do
      {:ok, fragment_count}
    else
      {:error,
       Error.new(:client, operation, :too_many_download_fragments,
         details: %{fragment_count: fragment_count, limit: @maximum_download_fragments}
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
