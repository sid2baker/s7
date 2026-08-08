defmodule S7.Data do
  @moduledoc """
  Pure conversion between S7 scalar values and their big-endian wire bytes.
  """

  alias S7.Error

  @data_types [:bit, :byte, :word, :dword, :int, :dint, :real]

  @type data_type :: S7.Address.data_type()
  @type value :: boolean() | integer() | float()

  @doc """
  Encodes one typed Elixir value.
  """
  @spec encode(data_type(), value()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(:bit, value) when value in [false, 0], do: {:ok, <<0>>}
  def encode(:bit, value) when value in [true, 1], do: {:ok, <<1>>}
  def encode(:byte, value) when is_integer(value) and value in 0..0xFF, do: {:ok, <<value>>}

  def encode(:word, value) when is_integer(value) and value in 0..0xFFFF,
    do: {:ok, <<value::unsigned-big-16>>}

  def encode(:dword, value) when is_integer(value) and value in 0..0xFFFFFFFF,
    do: {:ok, <<value::unsigned-big-32>>}

  def encode(:int, value) when is_integer(value) and value in -0x8000..0x7FFF,
    do: {:ok, <<value::signed-big-16>>}

  def encode(:dint, value) when is_integer(value) and value in -0x80000000..0x7FFFFFFF,
    do: {:ok, <<value::signed-big-32>>}

  def encode(:real, value) when is_number(value) do
    {:ok, <<value * 1.0::float-big-32>>}
  rescue
    error in [ArgumentError, ArithmeticError] -> invalid(:real, value, error)
  end

  def encode(data_type, value) when data_type in @data_types, do: invalid(data_type, value)

  def encode(data_type, _value) do
    {:error,
     Error.new(:data, :encode, :data_type_not_supported, details: %{data_type: data_type})}
  end

  @doc """
  Decodes exactly one typed value. Trailing or truncated bytes are rejected.
  """
  @spec decode(data_type(), binary()) :: {:ok, value()} | {:error, Error.t()}
  def decode(:bit, <<0>>), do: {:ok, false}
  def decode(:bit, <<1>>), do: {:ok, true}
  def decode(:byte, <<value>>), do: {:ok, value}
  def decode(:word, <<value::unsigned-big-16>>), do: {:ok, value}
  def decode(:dword, <<value::unsigned-big-32>>), do: {:ok, value}
  def decode(:int, <<value::signed-big-16>>), do: {:ok, value}
  def decode(:dint, <<value::signed-big-32>>), do: {:ok, value}
  def decode(:real, <<value::float-big-32>>), do: {:ok, value}

  def decode(data_type, binary) when data_type in @data_types do
    {:error,
     Error.new(:data, :decode, :malformed_value,
       details: %{data_type: data_type, byte_size: byte_size_if_binary(binary)}
     )}
  end

  def decode(data_type, _binary) do
    {:error,
     Error.new(:data, :decode, :data_type_not_supported, details: %{data_type: data_type})}
  end

  @doc false
  @spec size(data_type()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def size(:bit), do: {:ok, 1}
  def size(:byte), do: {:ok, 1}
  def size(type) when type in [:word, :int], do: {:ok, 2}
  def size(type) when type in [:dword, :dint, :real], do: {:ok, 4}

  def size(data_type) do
    {:error, Error.new(:data, :size, :data_type_not_supported, details: %{data_type: data_type})}
  end

  defp invalid(data_type, value, _error \\ nil) do
    {:error,
     Error.new(:data, :encode, :value_out_of_range,
       details: %{data_type: data_type, value: value}
     )}
  end

  defp byte_size_if_binary(binary) when is_binary(binary), do: byte_size(binary)
  defp byte_size_if_binary(_other), do: nil
end
