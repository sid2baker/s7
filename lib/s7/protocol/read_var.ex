defmodule S7.Protocol.ReadVar do
  @moduledoc """
  Read Var request and response codec.

  One PDU may carry up to 255 S7ANY items. Response data items are decoded in
  request order and alignment padding is validated between items.
  """

  alias S7.{Address, Data, Error}
  alias S7.Protocol
  alias S7.Protocol.{DataItem, Item, PDU}

  @function 0x04
  @maximum_items 0xFF

  @type item_result(value) :: {:ok, value} | {:error, Error.t()}

  @doc """
  Builds a one-item Read Var Job PDU.
  """
  @spec request(Address.t(), 0..0xFFFF) :: {:ok, PDU.t()} | {:error, Error.t()}
  def request(%Address{} = address, reference), do: request_many([address], reference)

  @doc """
  Builds a multi-item Read Var Job PDU.
  """
  @spec request_many([Address.t()], 0..0xFFFF) :: {:ok, PDU.t()} | {:error, Error.t()}
  def request_many(addresses, reference) when is_list(addresses) do
    with :ok <- validate_item_count(addresses),
         {:ok, items} <- encode_items(addresses) do
      parameters = IO.iodata_to_binary([<<@function, length(addresses)>>, items])
      {:ok, PDU.new(:job, reference, parameters)}
    end
  end

  def request_many(addresses, _reference),
    do: Protocol.error(:read, :invalid_items, details: %{items: addresses})

  @doc """
  Decodes and converts a one-item Read Var response.
  """
  @spec decode_response(PDU.t(), Address.t(), 0..0xFFFF) ::
          {:ok, Data.value()} | {:error, Error.t()}
  def decode_response(%PDU{} = pdu, %Address{} = address, expected_reference) do
    with {:ok, [result]} <- decode_responses(pdu, [address], expected_reference) do
      result
    end
  end

  @doc """
  Decodes one response without converting its payload.
  """
  @spec decode_raw_response(PDU.t(), Address.t(), 0..0xFFFF) ::
          {:ok, binary()} | {:error, Error.t()}
  def decode_raw_response(%PDU{} = pdu, %Address{} = address, expected_reference) do
    with {:ok, [result]} <- decode_raw_responses(pdu, [address], expected_reference) do
      result
    end
  end

  @doc """
  Decodes typed multi-item results in request order. PLC item failures are
  returned as item-level errors without failing the complete response.
  """
  @spec decode_responses(PDU.t(), [Address.t()], 0..0xFFFF) ::
          {:ok, [item_result(Data.value())]} | {:error, Error.t()}
  def decode_responses(%PDU{} = pdu, addresses, expected_reference) when is_list(addresses),
    do: decode_many(pdu, addresses, expected_reference, false)

  @doc """
  Decodes raw multi-item results in request order.
  """
  @spec decode_raw_responses(PDU.t(), [Address.t()], 0..0xFFFF) ::
          {:ok, [item_result(binary())]} | {:error, Error.t()}
  def decode_raw_responses(%PDU{} = pdu, addresses, expected_reference)
      when is_list(addresses),
      do: decode_many(pdu, addresses, expected_reference, true)

  @doc false
  @spec response_size(Address.t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def response_size(%Address{} = address) do
    with {:ok, payload_size} <- Data.encoded_size(address.data_type, address.count) do
      {:ok, 12 + 2 + 4 + payload_size}
    end
  end

  defp decode_many(pdu, addresses, expected_reference, raw?) do
    with :ok <- validate_item_count(addresses),
         :ok <- Protocol.validate_response(pdu, :read, expected_reference),
         :ok <- validate_parameters(pdu.parameters, length(addresses)),
         {:ok, results, <<>>} <- decode_data_items(pdu.data, addresses, raw?, []) do
      {:ok, Enum.reverse(results)}
    else
      {:ok, _results, remaining} ->
        Protocol.malformed(:read, %{trailing_data: byte_size(remaining)})

      {:more, needed} ->
        Protocol.malformed(:read, %{bytes_needed: needed})

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        Protocol.malformed(:read, %{codec_reason: reason})
    end
  end

  defp decode_data_items(remaining, [], _raw?, results), do: {:ok, results, remaining}

  defp decode_data_items(data, [address | addresses], raw?, results) do
    with {:ok, item, remaining} <- DataItem.decode(data),
         {:ok, result} <- decode_item(item, address, raw?),
         {:ok, remaining} <- consume_padding(remaining, item, addresses) do
      decode_data_items(remaining, addresses, raw?, [result | results])
    end
  end

  defp decode_item(item, address, raw?) do
    case Protocol.item_result(:read, item.return_code) do
      :ok -> decode_successful_item(item, address, raw?)
      {:error, %Error{} = error} -> {:ok, {:error, error}}
    end
  end

  defp decode_successful_item(item, address, true) do
    with :ok <- validate_item(item, address) do
      {:ok, {:ok, item.data}}
    end
  end

  defp decode_successful_item(item, address, false) do
    with :ok <- validate_item(item, address),
         {:ok, value} <- Data.decode(address.data_type, item.data, address.count) do
      {:ok, {:ok, value}}
    end
  end

  defp consume_padding(remaining, _item, []), do: {:ok, remaining}

  defp consume_padding(remaining, item, _addresses) when rem(byte_size(item.data), 2) == 0,
    do: {:ok, remaining}

  defp consume_padding(<<_padding, remaining::binary>>, _item, _addresses), do: {:ok, remaining}
  defp consume_padding(<<>>, _item, _addresses), do: {:more, 1}

  defp validate_parameters(<<@function, count>>, count), do: :ok

  defp validate_parameters(parameters, expected_count),
    do: Protocol.malformed(:read, %{parameters: parameters, expected_count: expected_count})

  defp validate_item(item, address) do
    expected_transport = DataItem.expected_transport(address.data_type)

    with true <- item.transport_size == expected_transport,
         {:ok, expected_size} <- Data.encoded_size(address.data_type, address.count),
         true <- byte_size(item.data) == expected_size,
         true <-
           item.encoded_length ==
             DataItem.expected_encoded_length(address.data_type, expected_size) do
      :ok
    else
      _other ->
        Protocol.malformed(:read, %{
          expected_transport: expected_transport,
          received_transport: item.transport_size,
          payload_size: byte_size(item.data)
        })
    end
  end

  defp encode_items(addresses) do
    addresses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {address, index}, {:ok, items} ->
      case Item.from_address(address) do
        {:ok, item} -> {:cont, {:ok, [Item.encode(item) | items]}}
        {:error, %Error{} = error} -> {:halt, {:error, add_index(error, index)}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, error} -> {:error, error}
    end
  end

  defp validate_item_count(addresses) when length(addresses) in 1..@maximum_items, do: :ok

  defp validate_item_count(addresses),
    do: Protocol.error(:read, :invalid_item_count, details: %{count: length(addresses)})

  defp add_index(error, index), do: %{error | details: Map.put(error.details, :index, index)}
end
