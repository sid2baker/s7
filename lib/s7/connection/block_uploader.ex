defmodule S7.Connection.BlockUploader do
  @moduledoc false

  alias S7.{Block, BlockImage, Connection, Error}
  alias S7.Connection.TransactionCleanup
  alias S7.Protocol.BlockUpload

  @spec validate_options(term(), atom()) ::
          {:ok, BlockUpload.limits()} | {:error, Error.t()}
  def validate_options(opts, operation), do: BlockUpload.validate_options(opts, operation)

  @spec upload(pid(), Block.t(), BlockUpload.limits(), boolean(), atom()) ::
          {:ok, BlockImage.t() | binary()} | {:error, Error.t()}
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
      :ok -> BlockImage.decode(raw, transaction.block, transaction.operation)
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
end
