defmodule S7.Data do
  @moduledoc """
  Pure conversion between typed S7 values and their big-endian wire bytes.
  """

  alias S7.Error

  @data_types [:bit, :byte, :word, :dword, :int, :dint, :real]

  @type data_type :: S7.Address.data_type()
  @type scalar_value :: boolean() | integer() | float()
  @type value :: scalar_value() | [scalar_value()]

  @doc """
  Encodes one typed Elixir value.
  """
  @spec encode(data_type(), scalar_value()) :: {:ok, binary()} | {:error, Error.t()}
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
  Encodes exactly `count` consecutive values. A count of one preserves scalar
  semantics; larger counts require a list of the same length.
  """
  @spec encode(data_type(), value(), pos_integer()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(data_type, value, 1), do: encode(data_type, value)

  def encode(:bit, _values, count) when is_integer(count) and count > 1 do
    {:error, Error.new(:data, :encode, :multiple_bits_not_supported, details: %{count: count})}
  end

  def encode(data_type, values, count)
      when data_type in @data_types and is_list(values) and is_integer(count) and
             count in 2..0xFFFF do
    if length(values) == count do
      encode_values(data_type, values)
    else
      count_mismatch(:encode, count, length(values))
    end
  end

  def encode(data_type, _value, count)
      when data_type in @data_types and (not is_integer(count) or count not in 1..0xFFFF) do
    {:error,
     Error.new(:data, :encode, :invalid_count, details: %{data_type: data_type, count: count})}
  end

  def encode(data_type, value, count) when data_type in @data_types do
    {:error,
     Error.new(:data, :encode, :value_count_mismatch, details: %{count: count, value: value})}
  end

  def encode(data_type, _value, _count) do
    {:error,
     Error.new(:data, :encode, :data_type_not_supported, details: %{data_type: data_type})}
  end

  @doc """
  Decodes exactly one typed value. Trailing or truncated bytes are rejected.
  """
  @spec decode(data_type(), binary()) :: {:ok, scalar_value()} | {:error, Error.t()}
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

  @doc """
  Decodes exactly `count` consecutive values. A count of one returns a scalar;
  larger counts return a list in wire order.
  """
  @spec decode(data_type(), binary(), pos_integer()) :: {:ok, value()} | {:error, Error.t()}
  def decode(data_type, binary, 1), do: decode(data_type, binary)

  def decode(:bit, _binary, count) when is_integer(count) and count > 1 do
    {:error, Error.new(:data, :decode, :multiple_bits_not_supported, details: %{count: count})}
  end

  def decode(data_type, binary, count)
      when data_type in @data_types and is_binary(binary) and is_integer(count) and
             count in 2..0xFFFF do
    with {:ok, expected_size} <- encoded_size(data_type, count),
         :ok <- validate_binary_size(:decode, binary, expected_size),
         {:ok, element_size} <- size(data_type) do
      decode_values(data_type, binary, element_size, [])
    end
  end

  def decode(data_type, _binary, count)
      when data_type in @data_types and (not is_integer(count) or count not in 1..0xFFFF) do
    {:error,
     Error.new(:data, :decode, :invalid_count, details: %{data_type: data_type, count: count})}
  end

  def decode(data_type, binary, count) when data_type in @data_types do
    {:error,
     Error.new(:data, :decode, :malformed_value,
       details: %{data_type: data_type, count: count, byte_size: byte_size_if_binary(binary)}
     )}
  end

  def decode(data_type, _binary, _count) do
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

  @doc """
  Returns the exact payload size for a typed count.
  """
  @spec encoded_size(data_type(), pos_integer()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def encoded_size(:bit, count) when is_integer(count) and count > 1 do
    {:error, Error.new(:data, :size, :multiple_bits_not_supported, details: %{count: count})}
  end

  def encoded_size(data_type, count) when is_integer(count) and count in 1..0xFFFF do
    with {:ok, element_size} <- size(data_type) do
      {:ok, element_size * count}
    end
  end

  def encoded_size(data_type, count) do
    {:error,
     Error.new(:data, :size, :invalid_count, details: %{data_type: data_type, count: count})}
  end

  @doc """
  Validates already encoded bytes for a typed count.
  """
  @spec validate_raw(data_type(), binary(), pos_integer()) ::
          {:ok, binary()} | {:error, Error.t()}
  def validate_raw(data_type, binary, count) when is_binary(binary) do
    with {:ok, expected_size} <- encoded_size(data_type, count),
         :ok <- validate_binary_size(:encode, binary, expected_size) do
      {:ok, binary}
    end
  end

  def validate_raw(data_type, binary, count) do
    {:error,
     Error.new(:data, :encode, :raw_size_mismatch,
       details: %{data_type: data_type, count: count, value: binary}
     )}
  end

  defp invalid(data_type, value, _error \\ nil) do
    {:error,
     Error.new(:data, :encode, :value_out_of_range,
       details: %{data_type: data_type, value: value}
     )}
  end

  defp encode_values(data_type, values) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, encoded} ->
      case encode(data_type, value) do
        {:ok, binary} -> {:cont, {:ok, [binary | encoded]}}
        {:error, %Error{} = error} -> {:halt, {:error, add_index(error, index)}}
      end
    end)
    |> case do
      {:ok, encoded} -> {:ok, encoded |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_values(_data_type, <<>>, _element_size, values),
    do: {:ok, Enum.reverse(values)}

  defp decode_values(data_type, binary, element_size, values) do
    <<element::binary-size(element_size), remaining::binary>> = binary
    {:ok, value} = decode(data_type, element)
    decode_values(data_type, remaining, element_size, [value | values])
  end

  defp validate_binary_size(_operation, binary, expected_size)
       when byte_size(binary) == expected_size,
       do: :ok

  defp validate_binary_size(operation, binary, expected_size) do
    {:error,
     Error.new(:data, operation, :raw_size_mismatch,
       details: %{expected_size: expected_size, received_size: byte_size(binary)}
     )}
  end

  defp count_mismatch(operation, expected, received) do
    {:error,
     Error.new(:data, operation, :value_count_mismatch,
       details: %{expected: expected, received: received}
     )}
  end

  defp add_index(error, index), do: %{error | details: Map.put(error.details, :index, index)}

  defp byte_size_if_binary(binary) when is_binary(binary), do: byte_size(binary)
  defp byte_size_if_binary(_other), do: nil
end
