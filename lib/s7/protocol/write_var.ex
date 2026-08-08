defmodule S7.Protocol.WriteVar do
  @moduledoc """
  Single-item Write Var request and response codec.
  """

  alias S7.Address
  alias S7.Protocol
  alias S7.Protocol.{DataItem, Item, PDU}

  @function 0x05

  @doc """
  Builds a one-item Write Var Job PDU from an already-encoded scalar value.
  """
  @spec request(Address.t(), binary(), 0..0xFFFF) ::
          {:ok, PDU.t()} | {:error, S7.Error.t()}
  def request(%Address{} = address, value, reference) when is_binary(value) do
    with {:ok, item} <- Item.from_address(address) do
      parameters = <<@function, 1, Item.encode(item)::binary>>
      data = DataItem.for_write(address.data_type, value) |> DataItem.encode()
      {:ok, PDU.new(:job, reference, parameters, IO.iodata_to_binary(data))}
    end
  end

  @doc """
  Validates a one-item Write Var Ack-Data response.
  """
  @spec decode_response(PDU.t(), 0..0xFFFF) :: :ok | {:error, S7.Error.t()}
  def decode_response(%PDU{} = pdu, expected_reference) do
    with :ok <- Protocol.validate_response(pdu, :write, expected_reference),
         :ok <- validate_parameters(pdu.parameters),
         {:ok, return_code} <- decode_return_code(pdu.data) do
      Protocol.item_result(:write, return_code)
    end
  end

  defp validate_parameters(<<@function, 1>>), do: :ok
  defp validate_parameters(parameters), do: Protocol.malformed(:write, %{parameters: parameters})

  defp decode_return_code(<<return_code>>), do: {:ok, return_code}
  defp decode_return_code(data), do: Protocol.malformed(:write, %{data: data})
end
