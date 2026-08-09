defmodule S7.Protocol.Blocks do
  @moduledoc """
  Pure codecs and bounded continuation for classic block-directory userdata.

  Block upload and download are separate Job services and do not use this
  module.
  """

  import Bitwise

  alias S7.{Block, BlockEntry, BlockInfo, BlockInventory, Error}
  alias S7.Protocol.Blocks.Transaction
  alias S7.Protocol.UserData
  alias S7.Protocol.UserData.{Parameter, Payload}

  @list_all 0x01
  @list_type 0x02
  @block_info 0x03
  @octet_string 0x09
  @null 0x00
  @continuation 0x0A

  @type limits :: Block.limits()
  @typep consume_result ::
           {:ok, BlockInventory.t() | [BlockEntry.t()] | BlockInfo.t()}
           | {:continue, UserData.t(), Transaction.t()}
           | {:error, Error.t()}

  @doc false
  @spec validate_list_options(term(), atom()) :: {:ok, limits()} | {:error, Error.t()}
  defdelegate validate_list_options(opts, operation), to: Block

  @doc false
  @spec start_counts() :: {:ok, UserData.t(), Transaction.t()} | {:error, Error.t()}
  def start_counts do
    with {:ok, request} <-
           UserData.request(:blocks, @list_all, <<>>,
             return_code: @continuation,
             transport_size: @null
           ) do
      {:ok, request,
       %Transaction{
         action: :counts,
         max_bytes: 28,
         max_fragments: 1
       }}
    end
  end

  @doc false
  @spec start_list(Block.known_type(), limits()) ::
          {:ok, UserData.t(), Transaction.t()} | {:error, Error.t()}
  def start_list(type, %{max_bytes: max_bytes, max_fragments: max_fragments}) do
    with {:ok, type} <- Block.validate_request_type(type, :list_blocks),
         {:ok, request} <- UserData.request(:blocks, @list_type, Block.encode_type(type)) do
      {:ok, request,
       %Transaction{
         action: :list,
         type: type,
         max_bytes: max_bytes,
         max_fragments: max_fragments
       }}
    end
  end

  def start_list(_type, _limits),
    do: {:error, Error.new(:client, :list_blocks, :invalid_block_request)}

  @doc false
  @spec start_info(Block.t()) :: {:ok, UserData.t(), Transaction.t()} | {:error, Error.t()}
  def start_info(%Block{} = block) do
    with {:ok, %Block{type: type, number: number} = block} <-
           Block.validate(block, :block_info),
         data =
           IO.iodata_to_binary([
             Block.encode_type(type),
             number |> Integer.to_string() |> String.pad_leading(5, "0"),
             "A"
           ]),
         {:ok, request} <- UserData.request(:blocks, @block_info, data) do
      {:ok, request,
       %Transaction{
         action: :info,
         block: block,
         max_bytes: 78,
         max_fragments: 1
       }}
    end
  end

  def start_info(_block),
    do: {:error, Error.new(:client, :block_info, :invalid_block_request)}

  @doc false
  @spec consume(UserData.t(), Transaction.t(), atom()) :: consume_result()
  def consume(%UserData{} = response, %Transaction{} = transaction, operation) do
    with :ok <- validate_transport(response.payload, operation),
         {:ok, data_unit_reference, more?} <-
           fragment_parameters(response.parameter, transaction, operation),
         :ok <- validate_continuation(transaction, more?, operation),
         {:ok, transaction} <-
           append_fragment(
             transaction,
             response.payload.data,
             data_unit_reference,
             more?,
             operation
           ) do
      finish_or_continue(response, transaction, more?, operation)
    end
  end

  def consume(_response, _transaction, operation), do: malformed(operation, %{})

  @doc false
  @spec decode_inventory(binary(), atom()) :: {:ok, BlockInventory.t()} | {:error, Error.t()}
  def decode_inventory(raw, operation \\ :block_counts)

  def decode_inventory(raw, operation) when is_binary(raw) and byte_size(raw) == 28 do
    raw
    |> decode_count_records(%{}, operation)
    |> case do
      {:ok, counts} -> {:ok, %BlockInventory{counts: counts, raw: raw}}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def decode_inventory(raw, operation) when is_binary(raw),
    do: malformed(operation, %{expected_size: 28, received_size: byte_size(raw)})

  def decode_inventory(_raw, operation), do: malformed(operation, %{})

  @doc false
  @spec decode_entries(Block.known_type(), binary(), atom()) ::
          {:ok, [BlockEntry.t()]} | {:error, Error.t()}
  def decode_entries(type, raw, operation \\ :list_blocks)

  def decode_entries(type, raw, operation)
      when is_binary(raw) and rem(byte_size(raw), 4) == 0 do
    with {:ok, type} <- Block.validate_request_type(type, operation) do
      decode_entry_records(raw, type, [])
    end
  end

  def decode_entries(_type, raw, operation) when is_binary(raw),
    do: malformed(operation, %{record_size: 4, received_size: byte_size(raw)})

  def decode_entries(_type, _raw, operation), do: malformed(operation, %{})

  @doc false
  @spec decode_info(Block.t(), binary(), atom()) :: {:ok, BlockInfo.t()} | {:error, Error.t()}
  def decode_info(block, raw, operation \\ :block_info)

  def decode_info(%Block{} = requested, raw, operation)
      when is_binary(raw) and byte_size(raw) == 78 do
    <<raw_header::binary-size(9), flags, language_code, subtype_code, number::unsigned-big-16,
      load_memory_size::unsigned-big-32, security_code::unsigned-big-32,
      code_milliseconds::unsigned-big-32, code_days::unsigned-big-16,
      interface_milliseconds::unsigned-big-32, interface_days::unsigned-big-16,
      sbb_length::unsigned-big-16, additional_length::unsigned-big-16,
      local_data_length::unsigned-big-16, mc7_size::unsigned-big-16, author::binary-size(8),
      family::binary-size(8), name::binary-size(8), version, _unknown, checksum::unsigned-big-16,
      reserved::binary-size(8)>> = raw

    subtype = Block.decode_subtype(subtype_code)

    with :ok <- validate_info_header(raw_header, operation),
         :ok <- validate_block_identity(requested, subtype, number, operation),
         {:ok, code_timestamp} <-
           Block.decode_timestamp(
             code_milliseconds,
             code_days,
             :code_timestamp,
             operation,
             :malformed_response
           ),
         {:ok, interface_timestamp} <-
           Block.decode_timestamp(
             interface_milliseconds,
             interface_days,
             :interface_timestamp,
             operation,
             :malformed_response
           ) do
      {:ok,
       %BlockInfo{
         block: %Block{type: subtype, number: number},
         language: Block.decode_language(language_code),
         language_code: language_code,
         flags: flags,
         linked?: (flags &&& 0x01) != 0,
         standard?: (flags &&& 0x02) != 0,
         non_retain?: (flags &&& 0x08) != 0,
         load_memory_size: load_memory_size,
         security: decode_security(security_code),
         security_code: security_code,
         code_timestamp: code_timestamp,
         interface_timestamp: interface_timestamp,
         sbb_length: sbb_length,
         additional_length: additional_length,
         local_data_length: local_data_length,
         mc7_size: mc7_size,
         author: decode_text(author),
         family: decode_text(family),
         name: decode_text(name),
         version: {version >>> 4, version &&& 0x0F},
         checksum: checksum,
         raw_header: raw_header,
         reserved: reserved,
         raw: raw
       }}
    end
  end

  def decode_info(_block, raw, operation) when is_binary(raw),
    do: malformed(operation, %{expected_size: 78, received_size: byte_size(raw)})

  def decode_info(_block, _raw, operation), do: malformed(operation, %{})

  defp validate_transport(%Payload{transport_size: @octet_string}, _operation), do: :ok

  defp validate_transport(%Payload{transport_size: transport_size}, operation),
    do: malformed(operation, %{transport_size: transport_size})

  defp fragment_parameters(
         %Parameter{
           data_unit_reference: data_unit_reference,
           last_data_unit: last_data_unit,
           error_code: 0
         },
         transaction,
         operation
       )
       when data_unit_reference in 0..0xFF and last_data_unit in 0..0xFF do
    case transaction.data_unit_reference do
      nil ->
        {:ok, data_unit_reference, last_data_unit != 0}

      ^data_unit_reference ->
        {:ok, data_unit_reference, last_data_unit != 0}

      expected ->
        malformed(operation, %{expected_data_unit: expected, received: data_unit_reference})
    end
  end

  defp fragment_parameters(_parameter, _transaction, operation),
    do: malformed(operation, %{parameter_extension: :invalid})

  defp validate_continuation(%Transaction{action: :list}, _more?, _operation), do: :ok
  defp validate_continuation(_transaction, false, _operation), do: :ok

  defp validate_continuation(transaction, true, operation),
    do: malformed(operation, %{unexpected_continuation: transaction.action})

  defp append_fragment(transaction, chunk, data_unit_reference, more?, operation) do
    fragment_count = transaction.fragment_count + 1
    size = transaction.size + byte_size(chunk)

    cond do
      fragment_count > transaction.max_fragments or
          (more? and fragment_count >= transaction.max_fragments) ->
        {:error,
         Error.new(:s7, operation, :too_many_userdata_fragments,
           details: %{limit: transaction.max_fragments}
         )}

      size > transaction.max_bytes ->
        {:error,
         Error.new(:s7, operation, :userdata_too_large,
           details: %{size: size, limit: transaction.max_bytes}
         )}

      true ->
        {:ok,
         %{
           transaction
           | data_unit_reference: data_unit_reference,
             fragment_count: fragment_count,
             size: size,
             parts: [chunk | transaction.parts]
         }}
    end
  end

  defp finish_or_continue(response, %Transaction{action: :list} = transaction, true, _operation) do
    with {:ok, request} <- continuation_request(response.parameter.sequence) do
      {:continue, request, transaction}
    end
  end

  defp finish_or_continue(_response, transaction, false, operation) do
    raw = transaction.parts |> Enum.reverse() |> IO.iodata_to_binary()

    case transaction.action do
      :counts -> decode_inventory(raw, operation)
      :list -> decode_entries(transaction.type, raw, operation)
      :info -> decode_info(transaction.block, raw, operation)
    end
  end

  defp continuation_request(sequence) do
    UserData.request(:blocks, @list_type, <<>>,
      method: 0x12,
      sequence: sequence,
      data_unit_reference: 0,
      last_data_unit: 0,
      error_code: 0,
      return_code: @continuation,
      transport_size: @null
    )
  end

  defp decode_count_records(<<>>, counts, _operation), do: {:ok, counts}

  defp decode_count_records(
         <<type_code::unsigned-big-16, count::unsigned-big-16, rest::binary>>,
         counts,
         operation
       ) do
    type = Block.decode_type(type_code)

    if Map.has_key?(counts, type) do
      malformed(operation, %{duplicate_type: type_code})
    else
      decode_count_records(rest, Map.put(counts, type, count), operation)
    end
  end

  defp decode_entry_records(<<>>, _type, entries), do: {:ok, Enum.reverse(entries)}

  defp decode_entry_records(
         <<number::unsigned-big-16, flags, language_code, rest::binary>>,
         type,
         entries
       ) do
    record = <<number::unsigned-big-16, flags, language_code>>

    entry = %BlockEntry{
      block: %Block{type: type, number: number},
      flags: flags,
      language: Block.decode_language(language_code),
      language_code: language_code,
      raw: record
    }

    decode_entry_records(rest, type, [entry | entries])
  end

  defp validate_info_header(
         <<_type_marker::16, 74::16, _unknown::16, "pp", _marker>>,
         _operation
       ),
       do: :ok

  defp validate_info_header(header, operation),
    do: malformed(operation, %{block_info_header: header})

  defp validate_block_identity(%Block{type: type, number: number}, type, number, _operation),
    do: :ok

  defp validate_block_identity(requested, type, number, operation),
    do:
      malformed(operation, %{
        expected: {requested.type, requested.number},
        received: {type, number}
      })

  defp decode_security(0), do: :none
  defp decode_security(3), do: :know_how_protected
  defp decode_security(code), do: {:unknown, code}

  defp decode_text(binary) do
    binary
    |> :binary.split(<<0>>)
    |> hd()
    |> :unicode.characters_to_binary(:latin1, :utf8)
    |> String.trim_trailing()
  end

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
