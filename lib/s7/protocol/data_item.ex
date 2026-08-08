defmodule S7.Protocol.DataItem do
  @moduledoc """
  Codec for Read Var response and Write Var request data items.
  """

  @transport_codes %{none: 0x00, bit: 0x03, byte: 0x04, integer: 0x05, real: 0x07, octet: 0x09}
  @code_to_transport Map.new(@transport_codes, fn {name, code} -> {code, name} end)

  @enforce_keys [:return_code, :transport_size, :encoded_length, :data]
  defstruct [:return_code, :transport_size, :encoded_length, :data]

  @type transport_size :: :none | :bit | :byte | :integer | :real | :octet
  @type t :: %__MODULE__{
          return_code: byte(),
          transport_size: transport_size(),
          encoded_length: non_neg_integer(),
          data: binary()
        }

  @type decode_error :: :invalid_data_item | :unsupported_transport_size | :invalid_data_length

  @doc """
  Creates a Write Var data item for one already-encoded value.
  """
  @spec for_write(S7.Address.data_type(), binary()) :: t()
  def for_write(data_type, data) when is_binary(data) do
    transport_size = transport_for_data_type(data_type)

    %__MODULE__{
      return_code: 0,
      transport_size: transport_size,
      encoded_length: encoded_length(transport_size, byte_size(data)),
      data: data
    }
  end

  @doc """
  Encodes one data item as iodata.
  """
  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{} = item) do
    transport = Map.fetch!(@transport_codes, item.transport_size)
    validate_byte!(item.return_code)
    validate_length!(item.encoded_length)

    expected_size = payload_size(item.transport_size, item.encoded_length)

    if byte_size(item.data) != expected_size do
      raise ArgumentError, "data item payload does not match its encoded length"
    end

    [<<item.return_code, transport, item.encoded_length::unsigned-big-16>>, item.data]
  end

  @doc """
  Decodes one data item and returns the remaining data field.
  """
  @spec decode(binary()) ::
          {:ok, t(), binary()} | {:more, pos_integer()} | {:error, decode_error()}
  def decode(binary) when is_binary(binary) and byte_size(binary) < 4,
    do: {:more, 4 - byte_size(binary)}

  def decode(<<return_code, transport_code, encoded_length::unsigned-big-16, rest::binary>>) do
    with {:ok, transport_size} <- decode_transport(transport_code),
         {:ok, size} <- decode_payload_size(transport_size, encoded_length) do
      if byte_size(rest) < size do
        {:more, size - byte_size(rest)}
      else
        <<data::binary-size(size), remaining::binary>> = rest

        {:ok,
         %__MODULE__{
           return_code: return_code,
           transport_size: transport_size,
           encoded_length: encoded_length,
           data: data
         }, remaining}
      end
    end
  end

  def decode(_binary), do: {:error, :invalid_data_item}

  @doc false
  @spec expected_transport(S7.Address.data_type()) :: transport_size()
  def expected_transport(:bit), do: :bit
  def expected_transport(type) when type in [:byte, :word, :dword], do: :byte
  def expected_transport(type) when type in [:int, :dint], do: :integer
  def expected_transport(:real), do: :real

  @doc false
  @spec expected_encoded_length(S7.Address.data_type(), non_neg_integer()) :: non_neg_integer()
  def expected_encoded_length(data_type, payload_size) do
    data_type
    |> transport_for_data_type()
    |> encoded_length(payload_size)
  end

  defp transport_for_data_type(data_type), do: expected_transport(data_type)

  defp encoded_length(transport, payload_size) when transport in [:bit, :real, :octet],
    do: payload_size

  defp encoded_length(transport, payload_size) when transport in [:byte, :integer],
    do: payload_size * 8

  defp payload_size(:none, 0), do: 0
  defp payload_size(:none, _length), do: -1

  defp payload_size(transport, length) when transport in [:bit, :byte, :integer],
    do: div(length + 7, 8)

  defp payload_size(transport, length) when transport in [:real, :octet], do: length

  defp decode_payload_size(:none, 0), do: {:ok, 0}
  defp decode_payload_size(:none, _length), do: {:error, :invalid_data_length}

  defp decode_payload_size(transport, length) when transport in [:bit, :byte, :integer],
    do: {:ok, div(length + 7, 8)}

  defp decode_payload_size(transport, length) when transport in [:real, :octet],
    do: {:ok, length}

  defp decode_transport(code) do
    case @code_to_transport do
      %{^code => transport} -> {:ok, transport}
      _ -> {:error, :unsupported_transport_size}
    end
  end

  defp validate_byte!(value) when value in 0..0xFF, do: :ok
  defp validate_byte!(_value), do: raise(ArgumentError, "invalid data item return code")

  defp validate_length!(value) when value in 0..0xFFFF, do: :ok
  defp validate_length!(_value), do: raise(ArgumentError, "invalid data item length")
end
