defmodule S7.Protocol.BlockUpload do
  @moduledoc """
  Pure codecs and bounded assembly for the classic block-upload Job service.

  Upload is a stateful `Start Upload` / `Upload` / `End Upload` exchange. It is
  independent from Read Var and block-directory userdata services.
  """

  import Bitwise

  alias S7.{Block, Error, Options}
  alias S7.Protocol.{Job, PDU}

  @start_upload 0x1D
  @upload 0x1E
  @end_upload 0x1F
  @chunk_marker 0x00FB
  @default_max_bytes 1_048_576
  @default_max_fragments 64
  @default_timeout 30_000
  @maximum_bytes 16_777_216
  @maximum_fragments 4096
  @maximum_timeout 3_600_000

  @type limits :: %{
          max_bytes: pos_integer(),
          max_fragments: pos_integer(),
          timeout: pos_integer(),
          step_timeout: pos_integer() | nil
        }

  @typep transaction :: %{
           block: Block.t(),
           operation: atom(),
           upload_id: 0..0xFFFFFFFF | nil,
           advertised_size: pos_integer() | nil,
           max_bytes: pos_integer(),
           max_fragments: pos_integer(),
           fragment_count: non_neg_integer(),
           size: non_neg_integer(),
           parts: [binary()]
         }

  @typep consume_result ::
           {:continue, transaction()}
           | {:complete, binary(), transaction()}
           | {:error, Error.t()}

  @doc false
  @spec validate_options(term(), atom()) :: {:ok, limits()} | {:error, Error.t()}
  def validate_options(opts, operation) when is_list(opts) do
    allowed = [:max_bytes, :max_fragments, :timeout, :step_timeout]

    with :ok <- Options.validate_keys(opts, allowed, operation),
         {:ok, max_bytes} <-
           Options.positive(opts, :max_bytes, @default_max_bytes, @maximum_bytes, operation),
         {:ok, max_fragments} <-
           Options.positive(
             opts,
             :max_fragments,
             @default_max_fragments,
             @maximum_fragments,
             operation
           ),
         {:ok, timeout} <-
           Options.positive(opts, :timeout, @default_timeout, @maximum_timeout, operation),
         {:ok, step_timeout} <- optional_timeout(opts, operation) do
      {:ok,
       %{
         max_bytes: max_bytes,
         max_fragments: max_fragments,
         timeout: timeout,
         step_timeout: step_timeout
       }}
    end
  end

  def validate_options(opts, operation),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}

  @doc false
  @spec start_request(Block.t(), limits(), atom()) ::
          {:ok, PDU.t(), transaction()} | {:error, Error.t()}
  def start_request(%Block{} = block, limits, operation) do
    with {:ok, %Block{type: type, number: number} = block} <- Block.validate(block, operation),
         :ok <- validate_limits(limits, operation) do
      filename = Block.encode_filename(%Block{type: type, number: number}, :active)

      parameters = <<@start_upload, 0, 0::16, 0::32, byte_size(filename), filename::binary>>

      {:ok, PDU.new(:job, 0, parameters),
       %{
         block: block,
         operation: operation,
         upload_id: nil,
         advertised_size: nil,
         max_bytes: limits.max_bytes,
         max_fragments: limits.max_fragments,
         fragment_count: 0,
         size: 0,
         parts: []
       }}
    end
  end

  def start_request(_block, _limits, operation),
    do: {:error, Error.new(:client, operation, :invalid_block_request)}

  @doc false
  @spec consume_start(PDU.t(), transaction()) ::
          {:ok, transaction()} | {:error, Error.t()}
  def consume_start(%PDU{} = pdu, %{block: %Block{}} = transaction) do
    with :ok <- validate_response_header(pdu, transaction.operation),
         :ok <- validate_empty_data(pdu, transaction.operation),
         {:ok, upload_id, advertised_size} <-
           decode_start_parameters(pdu.parameters, transaction.operation) do
      {:ok,
       %{
         transaction
         | upload_id: upload_id,
           advertised_size: advertised_size
       }}
    end
  end

  def consume_start(_pdu, %{operation: operation}),
    do: malformed(operation, %{})

  @doc false
  @spec validate_advertised_size(transaction()) :: :ok | {:error, Error.t()}
  def validate_advertised_size(%{block: %Block{}} = transaction) do
    if transaction.advertised_size <= transaction.max_bytes do
      :ok
    else
      upload_too_large(transaction, transaction.advertised_size, transaction.max_bytes)
    end
  end

  @doc false
  @spec upload_request(transaction()) :: {:ok, PDU.t()} | {:error, Error.t()}
  def upload_request(%{upload_id: upload_id}) when upload_id in 0..0xFFFFFFFF do
    {:ok, PDU.new(:job, 0, <<@upload, 0, 0::16, upload_id::unsigned-big-32>>)}
  end

  def upload_request(%{operation: operation}),
    do: malformed(operation, %{transaction_state: :not_started})

  @doc false
  @spec consume_segment(PDU.t(), transaction()) :: consume_result()
  def consume_segment(%PDU{} = pdu, %{block: %Block{}} = transaction) do
    with :ok <- validate_response_header(pdu, transaction.operation),
         {:ok, more?} <- decode_upload_parameters(pdu.parameters, transaction.operation),
         {:ok, chunk} <- decode_chunk(pdu.data, transaction.operation),
         {:ok, transaction} <- append_chunk(transaction, chunk, more?) do
      finish_segment(transaction, more?)
    end
  end

  def consume_segment(_pdu, %{operation: operation}),
    do: malformed(operation, %{})

  @doc false
  @spec end_request(transaction()) :: {:ok, PDU.t()} | {:error, Error.t()}
  def end_request(%{upload_id: upload_id}) when upload_id in 0..0xFFFFFFFF do
    {:ok, PDU.new(:job, 0, <<@end_upload, 0, 0::16, upload_id::unsigned-big-32>>)}
  end

  def end_request(%{operation: operation}),
    do: malformed(operation, %{transaction_state: :not_started})

  @doc false
  @spec consume_end(PDU.t(), transaction()) :: :ok | {:error, Error.t()}
  def consume_end(%PDU{} = pdu, %{block: %Block{}} = transaction) do
    with :ok <- validate_response_header(pdu, transaction.operation),
         :ok <- validate_empty_data(pdu, transaction.operation),
         <<@end_upload>> <- pdu.parameters do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> malformed(transaction.operation, %{parameters: :invalid_end_upload})
    end
  end

  def consume_end(_pdu, %{operation: operation}),
    do: malformed(operation, %{})

  @doc false
  @spec initial_rejection?(Error.t()) :: boolean()
  def initial_rejection?(%Error{} = error), do: Job.complete_rejection?(error)

  @doc false
  @spec local_limit_error?(Error.t()) :: boolean()
  def local_limit_error?(%Error{reason: reason}) do
    reason in [:block_upload_too_large, :too_many_upload_fragments]
  end

  defp decode_start_parameters(
         <<@start_upload, 0, _unknown::16, upload_id::unsigned-big-32, length,
           size::binary-size(length)>>,
         operation
       )
       when upload_id > 0 and length > 0 do
    case Integer.parse(size) do
      {advertised_size, ""} when advertised_size > 0 -> {:ok, upload_id, advertised_size}
      _other -> malformed(operation, %{advertised_size: size})
    end
  end

  defp decode_start_parameters(parameters, operation),
    do: malformed(operation, %{parameters: parameters})

  defp decode_upload_parameters(<<@upload, status>>, _operation) when status in [0, 1],
    do: {:ok, status == 1}

  defp decode_upload_parameters(<<@upload, status>>, operation) when (status &&& 0x02) != 0,
    do: {:error, Error.new(:s7, operation, :plc_error, code: status)}

  defp decode_upload_parameters(parameters, operation),
    do: malformed(operation, %{parameters: parameters})

  defp decode_chunk(
         <<length::unsigned-big-16, @chunk_marker::unsigned-big-16, chunk::binary-size(length)>>,
         _operation
       )
       when length > 0,
       do: {:ok, chunk}

  defp decode_chunk(data, operation), do: malformed(operation, %{data_size: byte_size(data)})

  defp append_chunk(transaction, chunk, more?) do
    fragment_count = transaction.fragment_count + 1
    size = transaction.size + byte_size(chunk)

    cond do
      fragment_count > transaction.max_fragments or
          (more? and fragment_count >= transaction.max_fragments) ->
        {:error,
         Error.new(:s7, transaction.operation, :too_many_upload_fragments,
           details: %{limit: transaction.max_fragments}
         )}

      size > transaction.max_bytes ->
        upload_too_large(transaction, size, transaction.max_bytes)

      size > transaction.advertised_size ->
        malformed(transaction.operation, %{
          advertised_size: transaction.advertised_size,
          received_size: size
        })

      more? and size == transaction.advertised_size ->
        malformed(transaction.operation, %{
          advertised_size: transaction.advertised_size,
          continuation: :unexpected
        })

      true ->
        {:ok,
         %{
           transaction
           | fragment_count: fragment_count,
             size: size,
             parts: [chunk | transaction.parts]
         }}
    end
  end

  defp finish_segment(transaction, true), do: {:continue, transaction}

  defp finish_segment(transaction, false) do
    if transaction.size == transaction.advertised_size do
      raw = transaction.parts |> Enum.reverse() |> IO.iodata_to_binary()
      {:complete, raw, transaction}
    else
      malformed(transaction.operation, %{
        advertised_size: transaction.advertised_size,
        received_size: transaction.size
      })
    end
  end

  defp validate_response_header(pdu, operation),
    do: Job.validate_response_header(pdu, operation)

  defp validate_empty_data(%PDU{data: <<>>}, _operation), do: :ok

  defp validate_empty_data(%PDU{data: data}, operation),
    do: malformed(operation, %{unexpected_data_size: byte_size(data)})

  defp optional_timeout(opts, operation) do
    case Keyword.fetch(opts, :step_timeout) do
      :error ->
        {:ok, nil}

      {:ok, value} when is_integer(value) and value > 0 and value <= @maximum_timeout ->
        {:ok, value}

      {:ok, value} ->
        invalid_option(operation, :step_timeout, value)
    end
  end

  defp validate_limits(
         %{max_bytes: max_bytes, max_fragments: max_fragments},
         _operation
       )
       when is_integer(max_bytes) and max_bytes > 0 and is_integer(max_fragments) and
              max_fragments > 0,
       do: :ok

  defp validate_limits(_limits, operation),
    do: {:error, Error.new(:client, operation, :invalid_options)}

  defp upload_too_large(transaction, size, limit) do
    {:error,
     Error.new(:s7, transaction.operation, :block_upload_too_large,
       details: %{size: size, limit: limit}
     )}
  end

  defp invalid_option(operation, option, value),
    do:
      {:error,
       Error.new(:client, operation, :invalid_option, details: %{option: option, value: value})}

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
