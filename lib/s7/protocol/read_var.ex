defmodule S7.Protocol.ReadVar do
  @moduledoc """
  Single-item Read Var request and response codec.
  """

  alias S7.{Address, Data}
  alias S7.Protocol
  alias S7.Protocol.{DataItem, Item, PDU}

  @function 0x04

  @doc """
  Builds a one-item Read Var Job PDU.
  """
  @spec request(Address.t(), 0..0xFFFF) :: {:ok, PDU.t()} | {:error, S7.Error.t()}
  def request(%Address{} = address, reference) do
    with {:ok, item} <- Item.from_address(address) do
      {:ok, PDU.new(:job, reference, <<@function, 1, Item.encode(item)::binary>>)}
    end
  end

  @doc """
  Decodes and converts a one-item Read Var response.
  """
  @spec decode_response(PDU.t(), Address.t(), 0..0xFFFF) ::
          {:ok, Data.value()} | {:error, S7.Error.t()}
  def decode_response(%PDU{} = pdu, %Address{} = address, expected_reference) do
    with {:ok, raw} <- decode_raw_response(pdu, address, expected_reference) do
      Data.decode(address.data_type, raw)
    end
  end

  @doc """
  Decodes a one-item Read Var response without converting the payload.
  """
  @spec decode_raw_response(PDU.t(), Address.t(), 0..0xFFFF) ::
          {:ok, binary()} | {:error, S7.Error.t()}
  def decode_raw_response(%PDU{} = pdu, %Address{} = address, expected_reference) do
    with :ok <- Protocol.validate_response(pdu, :read, expected_reference),
         :ok <- validate_parameters(pdu.parameters),
         {:ok, item, <<>>} <- decode_data_item(pdu.data),
         :ok <- Protocol.item_result(:read, item.return_code),
         :ok <- validate_item(item, address) do
      {:ok, item.data}
    else
      {:ok, _item, remaining} ->
        Protocol.malformed(:read, %{trailing_data: byte_size(remaining)})

      {:more, needed} ->
        Protocol.malformed(:read, %{bytes_needed: needed})

      {:error, %S7.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        Protocol.malformed(:read, %{codec_reason: reason})
    end
  end

  defp validate_parameters(<<@function, 1>>), do: :ok
  defp validate_parameters(parameters), do: Protocol.malformed(:read, %{parameters: parameters})

  defp decode_data_item(data), do: DataItem.decode(data)

  defp validate_item(item, address) do
    expected_transport = DataItem.expected_transport(address.data_type)

    with true <- item.transport_size == expected_transport,
         {:ok, expected_size} <- Data.size(address.data_type),
         true <- byte_size(item.data) == expected_size do
      :ok
    else
      _ ->
        Protocol.malformed(:read, %{
          expected_transport: expected_transport,
          received_transport: item.transport_size,
          payload_size: byte_size(item.data)
        })
    end
  end
end
