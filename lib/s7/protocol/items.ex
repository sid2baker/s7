defmodule S7.Protocol.Item do
  @moduledoc """
  Codec for one 12-byte S7ANY variable specification.
  """

  alias S7.Address

  @transport_codes %{
    bit: 0x01,
    byte: 0x02,
    char: 0x03,
    word: 0x04,
    int: 0x05,
    dword: 0x06,
    dint: 0x07,
    real: 0x08,
    date: 0x09,
    time_of_day: 0x0A,
    time: 0x0B,
    s5time: 0x0C,
    date_and_time: 0x0F,
    counter: 0x1C,
    timer: 0x1D
  }

  @code_to_transport Map.new(@transport_codes, fn {name, code} -> {code, name} end)

  @area_codes %{
    counters: 0x1C,
    timers: 0x1D,
    peripheral: 0x80,
    inputs: 0x81,
    outputs: 0x82,
    markers: 0x83,
    db: 0x84,
    instance_db: 0x85,
    local: 0x86,
    previous_local: 0x87
  }
  @code_to_area Map.new(@area_codes, fn {name, code} -> {code, name} end)

  @enforce_keys [:transport_size, :count, :db_number, :area, :bit_address]
  defstruct [:transport_size, :count, :db_number, :area, :bit_address]

  @type t :: %__MODULE__{
          transport_size: Address.transport_size(),
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
    with {:ok, address} <- Address.validate(address),
         {:ok, wire_count} <- Address.wire_count(address) do
      {:ok,
       %__MODULE__{
         transport_size: Address.transport_size(address),
         count: wire_count,
         db_number: address.db_number,
         area: address.area,
         bit_address: Address.wire_address(address)
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
  @spec transport_code(Address.transport_size()) :: byte()
  def transport_code(transport_size), do: Map.fetch!(@transport_codes, transport_size)

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

defmodule S7.Protocol.DataItem do
  @moduledoc "Codec for Read Var response and Write Var request data items."

  @transport_codes %{
    none: 0x00,
    bit: 0x03,
    byte: 0x04,
    integer: 0x05,
    dinteger: 0x06,
    real: 0x07,
    octet: 0x09
  }
  @code_to_transport Map.new(@transport_codes, fn {name, code} -> {code, name} end)

  @enforce_keys [:return_code, :transport_size, :encoded_length, :data]
  defstruct [:return_code, :transport_size, :encoded_length, :data]

  @type transport_size :: :none | :bit | :byte | :integer | :dinteger | :real | :octet
  @type t :: %__MODULE__{
          return_code: byte(),
          transport_size: transport_size(),
          encoded_length: non_neg_integer(),
          data: binary()
        }

  @type decode_error :: :invalid_data_item | :unsupported_transport_size | :invalid_data_length

  @doc "Creates a Write Var data item for one already-encoded value."
  @spec for_write(S7.Address.t() | S7.Address.data_type(), binary()) :: t()
  def for_write(%S7.Address{} = address, data) when is_binary(data) do
    transport_size = address |> S7.Address.transport_size() |> transport_for_s7any()

    %__MODULE__{
      return_code: 0,
      transport_size: transport_size,
      encoded_length: encoded_length(transport_size, byte_size(data)),
      data: data
    }
  end

  def for_write(data_type, data) when is_binary(data) do
    transport_size = transport_for_data_type(data_type)

    %__MODULE__{
      return_code: 0,
      transport_size: transport_size,
      encoded_length: encoded_length(transport_size, byte_size(data)),
      data: data
    }
  end

  @doc "Encodes one data item as iodata."
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

  @doc "Decodes one data item and returns the remaining data field."
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
        <<data::binary-size(^size), remaining::binary>> = rest

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
  @spec expected_transport(S7.Address.t() | S7.Address.data_type()) :: transport_size()
  def expected_transport(%S7.Address{} = address) do
    address
    |> S7.Address.transport_size()
    |> transport_for_s7any()
  end

  def expected_transport(:bit), do: :bit
  def expected_transport(type) when type in [:byte, :word, :dword], do: :byte
  def expected_transport(type) when type in [:int, :dint], do: :integer
  def expected_transport(:real), do: :real
  def expected_transport(type) when type in [:char, :counter, :timer], do: :octet
  def expected_transport(_type), do: :byte

  @doc false
  @spec expected_transports(S7.Address.t()) :: [transport_size()]
  def expected_transports(%S7.Address{} = address) do
    case S7.Address.transport_size(address) do
      :dint -> [:integer, :dinteger]
      _transport_size -> [expected_transport(address)]
    end
  end

  @doc false
  @spec expected_encoded_length(S7.Address.t() | S7.Address.data_type(), non_neg_integer()) ::
          non_neg_integer()
  def expected_encoded_length(data_type_or_address, payload_size) do
    data_type_or_address
    |> expected_transport()
    |> encoded_length(payload_size)
  end

  defp transport_for_data_type(data_type), do: expected_transport(data_type)

  defp encoded_length(transport, payload_size)
       when transport in [:bit, :dinteger, :real, :octet],
       do: payload_size

  defp encoded_length(transport, payload_size) when transport in [:byte, :integer],
    do: payload_size * 8

  defp payload_size(:none, 0), do: 0
  defp payload_size(:none, _length), do: -1

  defp payload_size(transport, length) when transport in [:bit, :byte, :integer],
    do: div(length + 7, 8)

  defp payload_size(transport, length) when transport in [:dinteger, :real, :octet], do: length

  defp decode_payload_size(:none, 0), do: {:ok, 0}
  defp decode_payload_size(:none, _length), do: {:error, :invalid_data_length}

  defp decode_payload_size(transport, length) when transport in [:bit, :byte, :integer],
    do: {:ok, div(length + 7, 8)}

  defp decode_payload_size(transport, length) when transport in [:dinteger, :real, :octet],
    do: {:ok, length}

  defp transport_for_s7any(:bit), do: :bit
  defp transport_for_s7any(type) when type in [:int, :dint], do: :integer
  defp transport_for_s7any(:real), do: :real
  defp transport_for_s7any(type) when type in [:char, :counter, :timer], do: :octet
  defp transport_for_s7any(_type), do: :byte

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
