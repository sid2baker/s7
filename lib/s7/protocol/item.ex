defmodule S7.Protocol.Item do
  @moduledoc """
  Codec for one 12-byte S7ANY variable specification.
  """

  alias S7.Address

  @transport_codes %{
    bit: 0x01,
    byte: 0x02,
    word: 0x04,
    int: 0x05,
    dword: 0x06,
    dint: 0x07,
    real: 0x08
  }

  @code_to_transport Map.new(@transport_codes, fn {name, code} -> {code, name} end)

  @area_codes %{inputs: 0x81, outputs: 0x82, markers: 0x83, db: 0x84}
  @code_to_area Map.new(@area_codes, fn {name, code} -> {code, name} end)

  @enforce_keys [:transport_size, :count, :db_number, :area, :bit_address]
  defstruct [:transport_size, :count, :db_number, :area, :bit_address]

  @type t :: %__MODULE__{
          transport_size: Address.data_type(),
          count: pos_integer(),
          db_number: non_neg_integer(),
          area: Address.area(),
          bit_address: 0..0xFFFFFF
        }

  @type decode_error ::
          :invalid_s7any_item
          | :invalid_specification_type
          | :invalid_syntax_id
          | :unsupported_transport_size
          | :unsupported_area

  @doc """
  Converts an address to its protocol-level S7ANY item.
  """
  @spec from_address(Address.t()) :: {:ok, t()} | {:error, S7.Error.t()}
  def from_address(%Address{} = address) do
    with {:ok, address} <- Address.validate(address) do
      {:ok,
       %__MODULE__{
         transport_size: address.data_type,
         count: address.count,
         db_number: address.db_number,
         area: address.area,
         bit_address: Address.bit_address(address)
       }}
    end
  end

  @doc """
  Encodes one S7ANY item.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = item) do
    transport = Map.fetch!(@transport_codes, item.transport_size)
    area = Map.fetch!(@area_codes, item.area)
    validate_word!(item.count, :count)
    validate_db_number!(item.db_number)
    validate_bit_address!(item.bit_address)

    <<0x12, 0x0A, 0x10, transport, item.count::unsigned-big-16, item.db_number::unsigned-big-16,
      area, item.bit_address::unsigned-big-24>>
  end

  @doc """
  Decodes one S7ANY item and returns trailing parameter bytes.
  """
  @spec decode(binary()) ::
          {:ok, t(), binary()} | {:more, pos_integer()} | {:error, decode_error()}
  def decode(binary) when is_binary(binary) and byte_size(binary) < 12,
    do: {:more, 12 - byte_size(binary)}

  def decode(
        <<0x12, 0x0A, 0x10, transport, count::unsigned-big-16, db_number::unsigned-big-16, area,
          bit_address::unsigned-big-24, remaining::binary>>
      )
      when count > 0 do
    with {:ok, transport_size} <- decode_transport(transport),
         {:ok, area} <- decode_area(area) do
      {:ok,
       %__MODULE__{
         transport_size: transport_size,
         count: count,
         db_number: db_number,
         area: area,
         bit_address: bit_address
       }, remaining}
    end
  end

  def decode(<<specification, _rest::binary>>) when specification != 0x12,
    do: {:error, :invalid_specification_type}

  def decode(<<0x12, _length, syntax, _rest::binary>>) when syntax != 0x10,
    do: {:error, :invalid_syntax_id}

  def decode(_binary), do: {:error, :invalid_s7any_item}

  @doc false
  @spec transport_code(Address.data_type()) :: byte()
  def transport_code(data_type), do: Map.fetch!(@transport_codes, data_type)

  @doc false
  @spec area_code(Address.area()) :: byte()
  def area_code(area), do: Map.fetch!(@area_codes, area)

  defp decode_transport(code) do
    case @code_to_transport do
      %{^code => transport} -> {:ok, transport}
      _ -> {:error, :unsupported_transport_size}
    end
  end

  defp decode_area(code) do
    case @code_to_area do
      %{^code => area} -> {:ok, area}
      _ -> {:error, :unsupported_area}
    end
  end

  defp validate_word!(value, _field) when value in 1..0xFFFF, do: :ok
  defp validate_word!(_value, field), do: raise(ArgumentError, "invalid #{field}")

  defp validate_db_number!(value) when value in 0..0xFFFF, do: :ok
  defp validate_db_number!(_value), do: raise(ArgumentError, "invalid DB number")

  defp validate_bit_address!(value) when value in 0..0xFFFFFF, do: :ok
  defp validate_bit_address!(_value), do: raise(ArgumentError, "invalid bit address")
end
