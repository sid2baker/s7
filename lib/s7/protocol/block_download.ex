defmodule S7.Protocol.BlockDownload do
  @moduledoc """
  Pure codecs for the classic PLC-driven block-download transaction.

  Download is not Write Var. After `Request Download`, the PLC sends one or
  more `Download Block` Jobs that the client answers with bounded image slices,
  followed by a `Download Ended` Job.
  """

  alias S7.{Block, BlockImage, Error}
  alias S7.Protocol.BlockDownload.Transaction
  alias S7.Protocol.{Job, PDU}

  @request_download 0x1A
  @download_block 0x1B
  @download_ended 0x1C
  @chunk_marker 0x00FB
  @maximum_image_size 999_999
  @response_overhead 18

  @type start_request :: %{
          block: Block.t(),
          load_memory_size: pos_integer(),
          mc7_size: non_neg_integer()
        }

  @type end_request :: %{block: Block.t(), error_code: 0..0xFFFF}

  @doc false
  @spec start_request(BlockImage.t(), atom()) ::
          {:ok, PDU.t(), Transaction.t()} | {:error, Error.t()}
  def start_request(%BlockImage{} = image, operation) do
    with {:ok, %Block{} = block} <- Block.validate(image.block, operation),
         :ok <- validate_image_size(image.raw, image.mc7_size, operation) do
      filename = Block.encode_filename(block, :passive)
      load_size = encode_size(byte_size(image.raw))
      mc7_size = encode_size(image.mc7_size)

      parameters =
        IO.iodata_to_binary([
          <<@request_download, 0, 0x0100::unsigned-big-16, 0::32, 9>>,
          filename,
          <<13, ?1>>,
          load_size,
          mc7_size
        ])

      {:ok, PDU.new(:job, 0, parameters),
       %Transaction{
         block: block,
         image: image.raw,
         mc7_size: image.mc7_size,
         operation: operation
       }}
    end
  end

  def start_request(_image, operation),
    do: {:error, Error.new(:client, operation, :invalid_block_image)}

  @doc false
  @spec decode_start_request(PDU.t(), atom()) ::
          {:ok, start_request()} | {:error, Error.t()}
  def decode_start_request(
        %PDU{
          header: %{rosctr: :job},
          parameters:
            <<@request_download, 0, 0x0100::unsigned-big-16, 0::32, 9, filename::binary-size(9),
              13, ?1, load_size::binary-size(6), mc7_size::binary-size(6)>>,
          data: <<>>
        },
        operation
      ) do
    with {:ok, block} <- decode_filename(filename, operation),
         {:ok, load_memory_size} <- decode_size(load_size, :load_memory_size, operation),
         {:ok, mc7_size} <- decode_size(mc7_size, :mc7_size, operation),
         :ok <- validate_declared_sizes(load_memory_size, mc7_size, operation) do
      {:ok, %{block: block, load_memory_size: load_memory_size, mc7_size: mc7_size}}
    end
  end

  def decode_start_request(_pdu, operation), do: malformed(operation, %{})

  @doc false
  @spec consume_start(PDU.t(), Transaction.t()) ::
          {:ok, Transaction.t()} | {:error, Error.t()}
  def consume_start(%PDU{} = pdu, %Transaction{stage: :request_download} = transaction) do
    with :ok <- validate_response_header(pdu, transaction.operation),
         <<@request_download>> <- pdu.parameters,
         <<>> <- pdu.data do
      {:ok, %{transaction | stage: :download}}
    else
      {:error, %Error{} = error} -> {:error, error}
      _other -> malformed(transaction.operation, %{parameters: pdu.parameters})
    end
  end

  def consume_start(_pdu, %Transaction{operation: operation}),
    do: malformed(operation, %{stage: :invalid})

  @doc false
  @spec consume_download_job(PDU.t(), Transaction.t(), pos_integer()) ::
          {:ok, PDU.t(), Transaction.t()} | {:error, Error.t()}
  def consume_download_job(
        %PDU{} = request,
        %Transaction{stage: :download} = transaction,
        pdu_size
      ) do
    with :ok <- validate_job(request, transaction, @download_block),
         :ok <- validate_download_parameters(request.parameters, transaction),
         {:ok, maximum_slice} <- maximum_slice(pdu_size, transaction.operation),
         :ok <- validate_reference(request.header.pdu_reference, transaction) do
      remaining = byte_size(transaction.image) - transaction.offset
      slice_size = min(remaining, maximum_slice)
      slice = binary_part(transaction.image, transaction.offset, slice_size)
      offset = transaction.offset + slice_size
      more? = offset < byte_size(transaction.image)
      status = if more?, do: 1, else: 0

      response =
        PDU.new(
          :ack_data,
          request.header.pdu_reference,
          <<@download_block, status>>,
          <<slice_size::unsigned-big-16, @chunk_marker::unsigned-big-16, slice::binary>>
        )

      transaction = %{
        transaction
        | offset: offset,
          fragment_count: transaction.fragment_count + 1,
          references: MapSet.put(transaction.references, request.header.pdu_reference),
          stage: if(more?, do: :download, else: :download_ended)
      }

      {:ok, response, transaction}
    end
  end

  def consume_download_job(_pdu, %Transaction{operation: operation}, _pdu_size),
    do: malformed(operation, %{stage: :invalid})

  @doc false
  @spec decode_download_response(PDU.t(), atom()) ::
          {:ok, %{more?: boolean(), data: binary()}} | {:error, Error.t()}
  def decode_download_response(
        %PDU{
          header: %{rosctr: :ack_data},
          parameters: <<@download_block, status>>,
          data:
            <<length::unsigned-big-16, @chunk_marker::unsigned-big-16, data::binary-size(length)>>
        },
        _operation
      )
      when status in [0, 1] and length > 0,
      do: {:ok, %{more?: status == 1, data: data}}

  def decode_download_response(_pdu, operation), do: malformed(operation, %{})

  @doc false
  @spec consume_end_job(PDU.t(), Transaction.t()) ::
          {:ok, PDU.t(), Transaction.t(), end_request()} | {:error, Error.t()}
  def consume_end_job(%PDU{} = request, %Transaction{stage: :download_ended} = transaction) do
    with :ok <- validate_job(request, transaction, @download_ended),
         {:ok, end_request} <- decode_end_parameters(request.parameters, transaction),
         :ok <- validate_reference(request.header.pdu_reference, transaction) do
      response = PDU.new(:ack_data, request.header.pdu_reference, <<@download_ended>>)

      transaction = %{
        transaction
        | stage: :complete,
          references: MapSet.put(transaction.references, request.header.pdu_reference)
      }

      {:ok, response, transaction, end_request}
    end
  end

  def consume_end_job(_pdu, %Transaction{operation: operation}),
    do: malformed(operation, %{stage: :invalid})

  @doc false
  @spec decode_end_response(PDU.t(), atom()) :: :ok | {:error, Error.t()}
  def decode_end_response(
        %PDU{header: %{rosctr: :ack_data}, parameters: <<@download_ended>>, data: <<>>},
        _operation
      ),
      do: :ok

  def decode_end_response(_pdu, operation), do: malformed(operation, %{})

  @doc false
  @spec complete_rejection?(Error.t()) :: boolean()
  def complete_rejection?(%Error{} = error), do: Job.complete_rejection?(error)

  @doc false
  @spec end_error(end_request(), atom()) :: :ok | {:error, Error.t()}
  def end_error(%{error_code: 0}, _operation), do: :ok

  def end_error(%{error_code: code}, operation),
    do: {:error, Error.new(:s7, operation, :block_download_rejected, code: code)}

  defp validate_image_size(raw, mc7_size, _operation)
       when is_binary(raw) and byte_size(raw) in 1..@maximum_image_size and
              mc7_size in 0..@maximum_image_size,
       do: :ok

  defp validate_image_size(raw, mc7_size, operation) do
    {:error,
     Error.new(:client, operation, :block_image_too_large,
       details: %{
         image_size: if(is_binary(raw), do: byte_size(raw), else: nil),
         mc7_size: mc7_size,
         limit: @maximum_image_size
       }
     )}
  end

  defp validate_declared_sizes(load_size, mc7_size, _operation)
       when load_size in 1..@maximum_image_size and mc7_size in 0..@maximum_image_size and
              mc7_size <= load_size,
       do: :ok

  defp validate_declared_sizes(load_size, mc7_size, operation),
    do: malformed(operation, %{load_memory_size: load_size, mc7_size: mc7_size})

  defp encode_size(size), do: size |> Integer.to_string() |> String.pad_leading(6, "0")

  defp decode_size(binary, field, operation) do
    case Integer.parse(binary) do
      {size, ""} -> {:ok, size}
      _other -> malformed(operation, %{field: field, value: binary})
    end
  end

  defp decode_filename(
         <<"_", type_code::unsigned-big-16, number::binary-size(5), "P">>,
         operation
       ) do
    with type when is_atom(type) <- Block.decode_type(type_code),
         {number, ""} <- Integer.parse(number),
         {:ok, block} <- Block.normalize(type, number, operation) do
      {:ok, block}
    else
      _other -> malformed(operation, %{filename: :invalid})
    end
  end

  defp decode_filename(_filename, operation), do: malformed(operation, %{filename: :invalid})

  defp validate_job(%PDU{header: %{rosctr: :job}, data: <<>>}, _transaction, _function),
    do: :ok

  defp validate_job(%PDU{} = pdu, transaction, function) do
    malformed(transaction.operation, %{
      function: function,
      rosctr: pdu.header.rosctr,
      data_size: byte_size(pdu.data)
    })
  end

  defp validate_download_parameters(
         <<@download_block, 0, 0::16, 0::32, 9, filename::binary-size(9)>>,
         transaction
       ) do
    validate_filename(filename, transaction)
  end

  defp validate_download_parameters(parameters, transaction),
    do: malformed(transaction.operation, %{parameters: parameters})

  defp decode_end_parameters(
         <<@download_ended, 0, error_code::unsigned-big-16, 0::32, 9, filename::binary-size(9)>>,
         transaction
       ) do
    with :ok <- validate_filename(filename, transaction) do
      {:ok, %{block: transaction.block, error_code: error_code}}
    end
  end

  defp decode_end_parameters(parameters, transaction),
    do: malformed(transaction.operation, %{parameters: parameters})

  defp validate_filename(filename, transaction) do
    if filename == Block.encode_filename(transaction.block, :passive),
      do: :ok,
      else: malformed(transaction.operation, %{block_identity: :changed})
  end

  defp validate_reference(reference, transaction) do
    if MapSet.member?(transaction.references, reference),
      do: malformed(transaction.operation, %{duplicate_pdu_reference: reference}),
      else: :ok
  end

  defp maximum_slice(pdu_size, _operation)
       when is_integer(pdu_size) and pdu_size > @response_overhead,
       do: {:ok, pdu_size - @response_overhead}

  defp maximum_slice(pdu_size, operation),
    do: {:error, Error.new(:s7, operation, :pdu_too_small, details: %{pdu_size: pdu_size})}

  defp validate_response_header(pdu, operation),
    do: Job.validate_response_header(pdu, operation)

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
