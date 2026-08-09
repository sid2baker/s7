defmodule S7.Address do
  @moduledoc """
  A typed S7 memory address.

  Addresses can be built directly or parsed from common absolute Siemens
  notation. `count` is the number of consecutive semantic values represented
  by the address. `transport_size` may override the S7ANY wire transport when
  a CPU supports a native representation; otherwise a broadly interoperable
  transport is selected from `data_type`.

  Counters and timers are element-addressed and use `element_offset`. All
  other areas are byte-addressed and use `byte_offset` plus an optional
  `bit_offset`.
  """

  alias S7.{Data, Error}

  @areas [
    :peripheral,
    :inputs,
    :outputs,
    :markers,
    :db,
    :instance_db,
    :local,
    :previous_local,
    :counters,
    :timers
  ]

  @transport_sizes [
    :bit,
    :byte,
    :char,
    :word,
    :int,
    :dword,
    :dint,
    :real,
    :date,
    :time_of_day,
    :time,
    :s5time,
    :date_and_time,
    :counter,
    :timer
  ]

  @transport_size_bytes %{
    byte: 1,
    char: 1,
    word: 2,
    int: 2,
    dword: 4,
    dint: 4,
    real: 4,
    date: 2,
    time_of_day: 4,
    time: 4,
    s5time: 2,
    date_and_time: 8,
    counter: 2,
    timer: 2
  }

  @element_areas [:counters, :timers]
  @db_areas [:db, :instance_db]
  @maximum_wire_address 0xFFFFFF

  @enforce_keys [:area, :data_type]
  defstruct [
    :area,
    :byte_offset,
    :element_offset,
    :data_type,
    :transport_size,
    db_number: 0,
    bit_offset: nil,
    count: 1
  ]

  @type area ::
          :peripheral
          | :inputs
          | :outputs
          | :markers
          | :db
          | :instance_db
          | :local
          | :previous_local
          | :counters
          | :timers

  @type transport_size ::
          :bit
          | :byte
          | :char
          | :word
          | :int
          | :dword
          | :dint
          | :real
          | :date
          | :time_of_day
          | :time
          | :s5time
          | :date_and_time
          | :counter
          | :timer

  @type data_type :: Data.data_type()

  @type t :: %__MODULE__{
          area: area(),
          db_number: non_neg_integer(),
          byte_offset: non_neg_integer() | nil,
          element_offset: non_neg_integer() | nil,
          bit_offset: 0..7 | nil,
          data_type: data_type(),
          transport_size: transport_size() | nil,
          count: pos_integer()
        }

  @doc """
  Parses an absolute Siemens address.

  Supported forms include `DB1.DBX20.3`, `DB1.DBW20`, `DBI1.DBID4`, `MW10`,
  `I0.0`, `QW0`, `PB4`, `LW2`, `C10`, and `T5`. `DBD`/`MD` and equivalent
  forms are parsed as unsigned `:dword` values; construct an address explicitly
  when the same bytes represent another semantic type.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(address) when is_binary(address) do
    if String.valid?(address) do
      parse_string(address)
    else
      invalid(:invalid_address, %{address: address})
    end
  end

  def parse(address), do: invalid(:invalid_address, %{address: address})

  @doc """
  Validates and normalizes an address struct.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = address) do
    with :ok <- validate_area(address.area),
         :ok <- validate_data_type(address.data_type),
         :ok <- validate_db_number(address.area, address.db_number),
         :ok <- validate_count(address.data_type, address.count),
         {:ok, transport_size} <- resolve_transport_size(address),
         :ok <- validate_area_transport(address.area, address.data_type, transport_size),
         {:ok, wire_count} <- calculate_wire_count(address, transport_size),
         :ok <- validate_location(address, wire_count, transport_size) do
      db_number = if address.area in @db_areas, do: address.db_number, else: 0
      {:ok, %{address | db_number: db_number}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason, details} -> invalid(reason, details)
    end
  end

  def validate(address), do: invalid(:invalid_address, %{address: address})

  @doc false
  @spec validate_scalar(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate_scalar(%__MODULE__{} = address) do
    with {:ok, address} <- validate(address),
         :ok <- ensure_scalar(address.count) do
      {:ok, address}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason, details} -> invalid(reason, details)
    end
  end

  @doc """
  Returns the resolved S7ANY transport size.
  """
  @spec transport_size(t()) :: transport_size()
  def transport_size(%__MODULE__{transport_size: nil, data_type: data_type}),
    do: default_transport_size(data_type)

  def transport_size(%__MODULE__{transport_size: transport_size}), do: transport_size

  @doc """
  Returns the amount encoded in the S7ANY item.

  This may differ from semantic `count` when a value is transferred as bytes.
  """
  @spec wire_count(t()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def wire_count(%__MODULE__{} = address) do
    with {:ok, address} <- validate(address) do
      calculate_wire_count(address, transport_size(address))
    end
  end

  @doc false
  @spec wire_address(t()) :: non_neg_integer()
  def wire_address(%__MODULE__{area: area, element_offset: element_offset})
      when area in @element_areas,
      do: element_offset

  def wire_address(%__MODULE__{byte_offset: byte_offset, bit_offset: bit_offset}) do
    byte_offset * 8 + (bit_offset || 0)
  end

  @doc false
  @spec bit_address(t()) :: non_neg_integer()
  def bit_address(%__MODULE__{} = address), do: wire_address(address)

  defp parse_string(address) do
    address
    |> String.upcase()
    |> parse_normalized()
  end

  defp parse_normalized(address) do
    parsers = [
      &parse_db_bit/1,
      &parse_db_scalar/1,
      &parse_element/1,
      &parse_area_bit/1,
      &parse_area_scalar/1
    ]

    Enum.find_value(parsers, fn parser -> parser.(address) end) ||
      invalid(:invalid_address, %{address: address})
  end

  defp parse_db_bit(address) do
    case Regex.run(~r/\A(DB|DBI)(\d+)\.(DBX|DBIX)(\d+)\.(\d+)\z/, address) do
      [_, "DB" = prefix, db_number, "DBX", byte_offset, bit_offset] ->
        build_byte(db_area(prefix), db_number, byte_offset, bit_offset, :bit)

      [_, "DBI" = prefix, db_number, "DBIX", byte_offset, bit_offset] ->
        build_byte(db_area(prefix), db_number, byte_offset, bit_offset, :bit)

      _other ->
        nil
    end
  end

  defp parse_db_scalar(address) do
    case Regex.run(~r/\A(DB|DBI)(\d+)\.(DB|DBI)([BWD])(\d+)\z/, address) do
      [_, "DB" = prefix, db_number, "DB", kind, byte_offset] ->
        build_byte(db_area(prefix), db_number, byte_offset, nil, scalar_type(kind))

      [_, "DBI" = prefix, db_number, "DBI", kind, byte_offset] ->
        build_byte(db_area(prefix), db_number, byte_offset, nil, scalar_type(kind))

      _other ->
        nil
    end
  end

  defp parse_element(address) do
    case Regex.run(~r/\A([CT])(\d+)\z/, address) do
      [_, "C", element_offset] -> build_element(:counters, element_offset, :counter)
      [_, "T", element_offset] -> build_element(:timers, element_offset, :timer)
      nil -> nil
    end
  end

  defp parse_area_bit(address) do
    case Regex.run(~r/\A([PMIQLV])(\d+)\.(\d+)\z/, address) do
      [_, area, byte_offset, bit_offset] ->
        build_byte(area(area), 0, byte_offset, bit_offset, :bit)

      nil ->
        nil
    end
  end

  defp parse_area_scalar(address) do
    case Regex.run(~r/\A(P|M|I|Q|L|V)([BWD])(\d+)\z/, address) do
      [_, area, kind, byte_offset] ->
        build_byte(area(area), 0, byte_offset, nil, scalar_type(kind))

      nil ->
        nil
    end
  end

  defp build_byte(area, db_number, byte_offset, bit_offset, data_type) do
    address = %__MODULE__{
      area: area,
      db_number: to_integer(db_number),
      byte_offset: to_integer(byte_offset),
      bit_offset: to_integer(bit_offset),
      data_type: data_type
    }

    validate(address)
  end

  defp build_element(area, element_offset, data_type) do
    validate(%__MODULE__{
      area: area,
      element_offset: to_integer(element_offset),
      data_type: data_type
    })
  end

  defp to_integer(nil), do: nil
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value), do: String.to_integer(value)

  defp db_area("DB"), do: :db
  defp db_area("DBI"), do: :instance_db

  defp area("P"), do: :peripheral
  defp area("M"), do: :markers
  defp area("I"), do: :inputs
  defp area("Q"), do: :outputs
  defp area("L"), do: :local
  defp area("V"), do: :previous_local

  defp scalar_type("B"), do: :byte
  defp scalar_type("W"), do: :word
  defp scalar_type("D"), do: :dword

  defp validate_area(area) when area in @areas, do: :ok
  defp validate_area(area), do: {:error, :unsupported_area, %{area: area}}

  defp validate_data_type(data_type) do
    case Data.size(data_type) do
      {:ok, _size} -> :ok
      {:error, %Error{}} -> {:error, :data_type_not_supported, %{data_type: data_type}}
    end
  end

  defp validate_db_number(area, db_number)
       when area in @db_areas and db_number in 1..0xFFFF,
       do: :ok

  defp validate_db_number(area, db_number) when area in @db_areas,
    do: {:error, :invalid_db_number, %{area: area, db_number: db_number}}

  defp validate_db_number(_area, db_number) when db_number in [nil, 0], do: :ok

  defp validate_db_number(area, db_number),
    do: {:error, :invalid_db_number, %{area: area, db_number: db_number}}

  defp validate_count(:bit, 1), do: :ok

  defp validate_count(:bit, count) when is_integer(count) and count in 2..0xFFFF,
    do: {:error, :multiple_bits_not_supported, %{count: count}}

  defp validate_count(_data_type, count) when is_integer(count) and count in 1..0xFFFF, do: :ok
  defp validate_count(_data_type, count), do: {:error, :invalid_count, %{count: count}}

  defp resolve_transport_size(address) do
    transport_size = transport_size(address)

    if transport_size in @transport_sizes do
      {:ok, transport_size}
    else
      {:error, :unsupported_transport_size, %{transport_size: transport_size}}
    end
  end

  defp validate_area_transport(:counters, :counter, :counter), do: :ok
  defp validate_area_transport(:timers, :timer, :timer), do: :ok

  defp validate_area_transport(area, data_type, transport_size) when area in @element_areas,
    do:
      {:error, :invalid_area_data_type,
       %{area: area, data_type: data_type, transport_size: transport_size}}

  defp validate_area_transport(_area, :counter, _transport_size),
    do: {:error, :invalid_area_data_type, %{data_type: :counter}}

  defp validate_area_transport(_area, :timer, _transport_size),
    do: {:error, :invalid_area_data_type, %{data_type: :timer}}

  defp validate_area_transport(_area, :bit, :bit), do: :ok

  defp validate_area_transport(_area, :bit, transport_size),
    do: {:error, :invalid_transport_size, %{data_type: :bit, transport_size: transport_size}}

  defp validate_area_transport(_area, _data_type, :bit),
    do: {:error, :invalid_transport_size, %{transport_size: :bit}}

  defp validate_area_transport(_area, _data_type, _transport_size), do: :ok

  defp calculate_wire_count(%__MODULE__{count: count}, :bit), do: {:ok, count}

  defp calculate_wire_count(%__MODULE__{} = address, transport_size) do
    with {:ok, semantic_size} <- Data.encoded_size(address.data_type, address.count),
         {:ok, transport_bytes} <- transport_size_bytes(transport_size),
         true <- rem(semantic_size, transport_bytes) == 0 do
      count = div(semantic_size, transport_bytes)

      if count in 1..0xFFFF do
        {:ok, count}
      else
        {:error, :invalid_wire_count, %{count: count, transport_size: transport_size}}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      false ->
        {:error, :invalid_transport_size,
         %{data_type: address.data_type, transport_size: transport_size}}
    end
  end

  defp transport_size_bytes(transport_size) do
    case @transport_size_bytes do
      %{^transport_size => size} -> {:ok, size}
      _other -> {:error, :invalid_transport_size, %{transport_size: transport_size}}
    end
  end

  defp validate_location(
         %__MODULE__{
           area: area,
           element_offset: element_offset,
           byte_offset: nil,
           bit_offset: nil,
           count: count
         },
         _wire_count,
         _transport_size
       )
       when area in @element_areas and is_integer(element_offset) and element_offset >= 0 and
              element_offset + count - 1 <= @maximum_wire_address,
       do: :ok

  defp validate_location(%__MODULE__{area: area} = address, _wire_count, _transport_size)
       when area in @element_areas,
       do: invalid_location(address)

  defp validate_location(
         %__MODULE__{
           byte_offset: byte_offset,
           element_offset: nil,
           bit_offset: bit_offset,
           data_type: :bit
         },
         1,
         :bit
       )
       when is_integer(byte_offset) and byte_offset >= 0 and bit_offset in 0..7 and
              byte_offset * 8 + bit_offset <= @maximum_wire_address,
       do: :ok

  defp validate_location(
         %__MODULE__{byte_offset: byte_offset, element_offset: nil, bit_offset: nil} = address,
         wire_count,
         transport_size
       )
       when is_integer(byte_offset) and byte_offset >= 0 do
    with {:ok, transport_bytes} <- transport_size_bytes(transport_size),
         last_bit = byte_offset * 8 + transport_bytes * wire_count * 8 - 1,
         true <- last_bit <= @maximum_wire_address do
      :ok
    else
      _other -> invalid_location(address)
    end
  end

  defp validate_location(address, _wire_count, _transport_size), do: invalid_location(address)

  defp invalid_location(address) do
    {:error, :invalid_offset,
     %{
       area: address.area,
       byte_offset: address.byte_offset,
       element_offset: address.element_offset,
       bit_offset: address.bit_offset,
       data_type: address.data_type
     }}
  end

  defp default_transport_size(:bit), do: :bit
  defp default_transport_size(type) when type in [:byte, :sint, :usint], do: :byte
  defp default_transport_size(:char), do: :char
  defp default_transport_size(type) when type in [:word, :uint], do: :word
  defp default_transport_size(:int), do: :int
  defp default_transport_size(type) when type in [:dword, :udint], do: :dword
  defp default_transport_size(:dint), do: :dint
  defp default_transport_size(:real), do: :real
  defp default_transport_size(:counter), do: :counter
  defp default_transport_size(:timer), do: :timer
  defp default_transport_size(_data_type), do: :byte

  defp ensure_scalar(1), do: :ok
  defp ensure_scalar(count), do: {:error, :multiple_values_not_supported, %{count: count}}

  defp invalid(reason, details) do
    {:error, Error.new(:address, :parse, reason, details: details)}
  end
end
