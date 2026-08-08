defmodule S7.Protocol.WriteVar do
  @moduledoc """
  Write Var request and response codec.

  Request data items are aligned to even offsets when another item follows.
  Ack-Data responses retain one PLC return code per requested item.
  """

  alias S7.{Address, Error}
  alias S7.Protocol
  alias S7.Protocol.{DataItem, Item, PDU}

  @function 0x05
  @maximum_items 0xFF

  @type encoded_item :: {Address.t(), binary()}
  @type item_result :: :ok | {:error, Error.t()}

  @doc """
  Builds a one-item Write Var Job PDU from an already encoded value.
  """
  @spec request(Address.t(), binary(), 0..0xFFFF) :: {:ok, PDU.t()} | {:error, Error.t()}
  def request(%Address{} = address, value, reference) when is_binary(value),
    do: request_many([{address, value}], reference)

  @doc """
  Builds a multi-item Write Var Job PDU from already encoded values.
  """
  @spec request_many([encoded_item()], 0..0xFFFF) :: {:ok, PDU.t()} | {:error, Error.t()}
  def request_many(items, reference) when is_list(items) do
    with :ok <- validate_item_count(items),
         {:ok, parameter_items, data_items} <- encode_items(items) do
      count = length(items)
      parameters = IO.iodata_to_binary([<<@function, count>>, parameter_items])
      data = IO.iodata_to_binary(data_items)
      {:ok, PDU.new(:job, reference, parameters, data)}
    end
  end

  def request_many(items, _reference),
    do: Protocol.error(:write, :invalid_items, details: %{items: items})

  @doc """
  Validates a one-item Write Var Ack-Data response.
  """
  @spec decode_response(PDU.t(), 0..0xFFFF) :: :ok | {:error, Error.t()}
  def decode_response(%PDU{} = pdu, expected_reference) do
    with {:ok, [result]} <- decode_responses(pdu, 1, expected_reference) do
      result
    end
  end

  @doc """
  Decodes one return code per requested item.
  """
  @spec decode_responses(PDU.t(), 1..255, 0..0xFFFF) ::
          {:ok, [item_result()]} | {:error, Error.t()}
  def decode_responses(%PDU{} = pdu, item_count, expected_reference)
      when item_count in 1..@maximum_items do
    with :ok <- Protocol.validate_response(pdu, :write, expected_reference),
         :ok <- validate_parameters(pdu.parameters, item_count),
         :ok <- validate_data_size(pdu.data, item_count) do
      {:ok, Enum.map(:binary.bin_to_list(pdu.data), &Protocol.item_result(:write, &1))}
    end
  end

  def decode_responses(_pdu, item_count, _expected_reference),
    do: Protocol.error(:write, :invalid_item_count, details: %{count: item_count})

  defp encode_items(items) do
    last_index = length(items) - 1

    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], []}, fn
      {{%Address{} = address, value}, index}, {:ok, parameter_items, data_items}
      when is_binary(value) ->
        case encode_item(address, value, index, last_index) do
          {:ok, parameter_item, data_item} ->
            {:cont, {:ok, [parameter_item | parameter_items], [data_item | data_items]}}

          {:error, %Error{} = error} ->
            {:halt, {:error, add_index(error, index)}}
        end

      {item, index}, _accumulator ->
        {:halt, Protocol.error(:write, :invalid_item, details: %{index: index, item: item})}
    end)
    |> case do
      {:ok, parameter_items, data_items} ->
        {:ok, Enum.reverse(parameter_items), Enum.reverse(data_items)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp encode_item(address, value, index, last_index) do
    case Item.from_address(address) do
      {:ok, item} ->
        data_item = DataItem.for_write(address.data_type, value) |> DataItem.encode()
        padding = if index < last_index and rem(byte_size(value), 2) == 1, do: <<0>>, else: <<>>
        {:ok, Item.encode(item), [data_item, padding]}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_parameters(<<@function, count>>, count), do: :ok

  defp validate_parameters(parameters, expected_count),
    do: Protocol.malformed(:write, %{parameters: parameters, expected_count: expected_count})

  defp validate_data_size(data, item_count) when byte_size(data) == item_count, do: :ok
  defp validate_data_size(data, _item_count), do: Protocol.malformed(:write, %{data: data})

  defp validate_item_count(items) when length(items) in 1..@maximum_items, do: :ok

  defp validate_item_count(items),
    do: Protocol.error(:write, :invalid_item_count, details: %{count: length(items)})

  defp add_index(error, index), do: %{error | details: Map.put(error.details, :index, index)}
end
