defmodule S7.Address do
  @moduledoc """
  A typed S7 memory address.

  Addresses can be built directly or parsed from common absolute Siemens
  notation. The v0.1 client supports one scalar value per address.
  """

  alias S7.Error

  @areas [:db, :inputs, :outputs, :markers]
  @data_types [:bit, :byte, :word, :dword, :int, :dint, :real]
  @maximum_bit_address 0xFFFFFF

  @enforce_keys [:area, :byte_offset, :data_type]
  defstruct [:area, :byte_offset, :data_type, db_number: 0, bit_offset: nil, count: 1]

  @type area :: :db | :inputs | :outputs | :markers
  @type data_type :: :bit | :byte | :word | :dword | :int | :dint | :real
  @type t :: %__MODULE__{
          area: area(),
          db_number: non_neg_integer(),
          byte_offset: non_neg_integer(),
          bit_offset: 0..7 | nil,
          data_type: data_type(),
          count: pos_integer()
        }

  @doc """
  Parses an absolute Siemens address.

  Supported forms include `DB1.DBX20.3`, `DB1.DBB20`, `MW10`, `I0.0`, and
  `QW0`. `DBD`/`MD` are parsed as unsigned `:dword` values; construct an
  address explicitly when the same four bytes represent `:dint` or `:real`.
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

  defp parse_string(address) do
    address
    |> String.upcase()
    |> parse_normalized()
  end

  @doc """
  Validates and normalizes an address struct.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = address) do
    with :ok <- validate_area(address.area),
         :ok <- validate_data_type(address.data_type),
         :ok <- validate_db_number(address.area, address.db_number),
         :ok <- validate_offset(address.byte_offset, address.bit_offset, address.data_type),
         :ok <- validate_count(address.count) do
      db_number = if address.area == :db, do: address.db_number, else: 0
      {:ok, %{address | db_number: db_number}}
    else
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

  @doc false
  @spec bit_address(t()) :: non_neg_integer()
  def bit_address(%__MODULE__{byte_offset: byte_offset, bit_offset: bit_offset}) do
    byte_offset * 8 + (bit_offset || 0)
  end

  defp parse_normalized(address) do
    parsers = [
      &parse_db_bit/1,
      &parse_db_scalar/1,
      &parse_area_bit/1,
      &parse_area_scalar/1
    ]

    Enum.find_value(parsers, fn parser -> parser.(address) end) ||
      invalid(:invalid_address, %{address: address})
  end

  defp parse_db_bit(address) do
    case Regex.run(~r/\ADB(\d+)\.DBX(\d+)\.(\d+)\z/, address) do
      [_, db_number, byte_offset, bit_offset] ->
        build(:db, db_number, byte_offset, bit_offset, :bit)

      nil ->
        nil
    end
  end

  defp parse_db_scalar(address) do
    case Regex.run(~r/\ADB(\d+)\.DB([BWD])(\d+)\z/, address) do
      [_, db_number, kind, byte_offset] ->
        build(:db, db_number, byte_offset, nil, scalar_type(kind))

      nil ->
        nil
    end
  end

  defp parse_area_bit(address) do
    case Regex.run(~r/\A([MIQ])(\d+)\.(\d+)\z/, address) do
      [_, area, byte_offset, bit_offset] ->
        build(area(area), 0, byte_offset, bit_offset, :bit)

      nil ->
        nil
    end
  end

  defp parse_area_scalar(address) do
    case Regex.run(~r/\A([MIQ])([BWD])(\d+)\z/, address) do
      [_, area, kind, byte_offset] ->
        build(area(area), 0, byte_offset, nil, scalar_type(kind))

      nil ->
        nil
    end
  end

  defp build(area, db_number, byte_offset, bit_offset, data_type) do
    address = %__MODULE__{
      area: area,
      db_number: to_integer(db_number),
      byte_offset: to_integer(byte_offset),
      bit_offset: to_integer(bit_offset),
      data_type: data_type
    }

    validate(address)
  end

  defp to_integer(nil), do: nil
  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value), do: String.to_integer(value)

  defp area("M"), do: :markers
  defp area("I"), do: :inputs
  defp area("Q"), do: :outputs

  defp scalar_type("B"), do: :byte
  defp scalar_type("W"), do: :word
  defp scalar_type("D"), do: :dword

  defp validate_area(area) when area in @areas, do: :ok
  defp validate_area(area), do: {:error, :unsupported_area, %{area: area}}

  defp validate_data_type(data_type) when data_type in @data_types, do: :ok

  defp validate_data_type(data_type),
    do: {:error, :data_type_not_supported, %{data_type: data_type}}

  defp validate_db_number(:db, db_number) when db_number in 1..0xFFFF, do: :ok

  defp validate_db_number(:db, db_number),
    do: {:error, :invalid_db_number, %{db_number: db_number}}

  defp validate_db_number(_area, db_number) when db_number in [nil, 0], do: :ok

  defp validate_db_number(area, db_number),
    do: {:error, :invalid_db_number, %{area: area, db_number: db_number}}

  defp validate_offset(byte_offset, bit_offset, :bit)
       when is_integer(byte_offset) and byte_offset >= 0 and bit_offset in 0..7 and
              byte_offset * 8 + bit_offset <= @maximum_bit_address,
       do: :ok

  defp validate_offset(byte_offset, nil, data_type)
       when is_integer(byte_offset) and byte_offset >= 0 and data_type in @data_types and
              byte_offset * 8 <= @maximum_bit_address,
       do: :ok

  defp validate_offset(byte_offset, bit_offset, data_type),
    do:
      {:error, :invalid_offset,
       %{byte_offset: byte_offset, bit_offset: bit_offset, data_type: data_type}}

  defp validate_count(count) when is_integer(count) and count in 1..0xFFFF, do: :ok
  defp validate_count(count), do: {:error, :invalid_count, %{count: count}}

  defp ensure_scalar(1), do: :ok
  defp ensure_scalar(count), do: {:error, :multiple_values_not_supported, %{count: count}}

  defp invalid(reason, details) do
    {:error, Error.new(:address, :parse, reason, details: details)}
  end
end
