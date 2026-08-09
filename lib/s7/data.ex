defmodule S7.Data do
  @moduledoc """
  Pure conversion between typed S7 values and their big-endian wire bytes.

  The semantic value type is deliberately independent from the S7ANY
  transport selected by `S7.Address`. This permits interoperable byte access
  for values such as `DATE_AND_TIME` while retaining native S7ANY transport
  codes for peers that support them.

  Siemens `STRING` and `WSTRING` values have fixed storage footprints and are
  represented by `{:string, maximum_length}` and
  `{:wstring, maximum_length}` data types. `TIME`, `S5TIME`, and timer values
  are represented as integer milliseconds.
  """

  import Bitwise

  alias S7.Error

  @atom_data_types [
    :bit,
    :byte,
    :sint,
    :usint,
    :word,
    :uint,
    :dword,
    :udint,
    :lword,
    :int,
    :dint,
    :lint,
    :ulint,
    :real,
    :lreal,
    :char,
    :wchar,
    :date,
    :time,
    :time_of_day,
    :date_and_time,
    :s5time,
    :counter,
    :timer
  ]

  @date_epoch ~D[1990-01-01]
  @date_maximum ~D[2168-12-31]
  @maximum_string_length 254
  @maximum_wstring_length 16_382
  @milliseconds_per_day 86_400_000

  @type data_type ::
          :bit
          | :byte
          | :sint
          | :usint
          | :word
          | :uint
          | :dword
          | :udint
          | :lword
          | :int
          | :dint
          | :lint
          | :ulint
          | :real
          | :lreal
          | :char
          | :wchar
          | :date
          | :time
          | :time_of_day
          | :date_and_time
          | :s5time
          | :counter
          | :timer
          | {:string, 1..254}
          | {:wstring, 1..16_382}

  @type scalar_value ::
          boolean()
          | integer()
          | float()
          | binary()
          | Date.t()
          | Time.t()
          | NaiveDateTime.t()

  @type value :: scalar_value() | [scalar_value()]

  @doc """
  Encodes one typed Elixir value.
  """
  @spec encode(data_type(), scalar_value()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(:bit, value) when value in [false, 0], do: {:ok, <<0>>}
  def encode(:bit, value) when value in [true, 1], do: {:ok, <<1>>}

  def encode(type, value) when type in [:byte, :usint] and value in 0..0xFF,
    do: {:ok, <<value>>}

  def encode(:sint, value) when is_integer(value) and value in -0x80..0x7F,
    do: {:ok, <<value::signed-big-8>>}

  def encode(type, value) when type in [:word, :uint] and value in 0..0xFFFF,
    do: {:ok, <<value::unsigned-big-16>>}

  def encode(type, value) when type in [:dword, :udint] and value in 0..0xFFFFFFFF,
    do: {:ok, <<value::unsigned-big-32>>}

  def encode(type, value)
      when type in [:lword, :ulint] and is_integer(value) and value in 0..0xFFFFFFFFFFFFFFFF,
      do: {:ok, <<value::unsigned-big-64>>}

  def encode(:int, value) when is_integer(value) and value in -0x8000..0x7FFF,
    do: {:ok, <<value::signed-big-16>>}

  def encode(:dint, value) when is_integer(value) and value in -0x80000000..0x7FFFFFFF,
    do: {:ok, <<value::signed-big-32>>}

  def encode(:lint, value)
      when is_integer(value) and value in -0x8000000000000000..0x7FFFFFFFFFFFFFFF,
      do: {:ok, <<value::signed-big-64>>}

  def encode(:real, value) when is_number(value) do
    {:ok, <<value * 1.0::float-big-32>>}
  rescue
    error in [ArgumentError, ArithmeticError] -> invalid(:real, value, error)
  end

  def encode(:lreal, value) when is_number(value) do
    {:ok, <<value * 1.0::float-big-64>>}
  rescue
    error in [ArgumentError, ArithmeticError] -> invalid(:lreal, value, error)
  end

  def encode(:char, value) when is_binary(value) and byte_size(value) == 1, do: {:ok, value}

  def encode(:wchar, value) when is_binary(value) do
    with {:ok, encoded} <- utf16_encode(value),
         true <- byte_size(encoded) == 2 do
      {:ok, encoded}
    else
      _other -> invalid(:wchar, value)
    end
  end

  def encode(:date, %Date{} = value) do
    if Date.compare(value, @date_epoch) in [:eq, :gt] and
         Date.compare(value, @date_maximum) in [:eq, :lt] do
      {:ok, <<Date.diff(value, @date_epoch)::unsigned-big-16>>}
    else
      invalid(:date, value)
    end
  end

  def encode(:time, value)
      when is_integer(value) and value in -0x80000000..0x7FFFFFFF,
      do: {:ok, <<value::signed-big-32>>}

  def encode(:time_of_day, %Time{} = value) do
    case time_to_milliseconds(value) do
      {:ok, milliseconds} -> {:ok, <<milliseconds::unsigned-big-32>>}
      :error -> invalid(:time_of_day, value)
    end
  end

  def encode(:date_and_time, %NaiveDateTime{} = value) do
    case encode_date_and_time(value) do
      {:ok, encoded} -> {:ok, encoded}
      :error -> invalid(:date_and_time, value)
    end
  end

  def encode(type, value) when type in [:s5time, :timer] and is_integer(value) do
    case encode_s5time(value) do
      {:ok, encoded} -> {:ok, encoded}
      :error -> invalid(type, value)
    end
  end

  def encode(:counter, value) when is_integer(value) and value in 0..999,
    do: {:ok, <<encode_bcd(value, 3)::unsigned-big-16>>}

  def encode({:string, maximum_length} = type, value)
      when maximum_length in 1..@maximum_string_length and is_binary(value) do
    if byte_size(value) <= maximum_length do
      padding = :binary.copy(<<0>>, maximum_length - byte_size(value))
      {:ok, <<maximum_length, byte_size(value), value::binary, padding::binary>>}
    else
      invalid(type, value)
    end
  end

  def encode({:wstring, maximum_length} = type, value)
      when maximum_length in 1..@maximum_wstring_length and is_binary(value) do
    with {:ok, encoded} <- utf16_encode(value),
         current_length = div(byte_size(encoded), 2),
         true <- current_length <= maximum_length do
      padding = :binary.copy(<<0>>, (maximum_length - current_length) * 2)

      {:ok,
       <<maximum_length::unsigned-big-16, current_length::unsigned-big-16, encoded::binary,
         padding::binary>>}
    else
      _other -> invalid(type, value)
    end
  end

  def encode(data_type, value) do
    if supported_type?(data_type) do
      invalid(data_type, value)
    else
      unsupported(:encode, data_type)
    end
  end

  @doc """
  Encodes exactly `count` consecutive values. A count of one preserves scalar
  semantics; larger counts require a list of the same length.
  """
  @spec encode(data_type(), value(), pos_integer()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(data_type, value, 1), do: encode(data_type, value)

  def encode(:bit, _value, count) when is_integer(count) and count > 1 do
    {:error, Error.new(:data, :encode, :multiple_bits_not_supported, details: %{count: count})}
  end

  def encode(data_type, value, count) do
    if supported_type?(data_type) do
      encode_counted(data_type, value, count)
    else
      unsupported(:encode, data_type)
    end
  end

  @doc """
  Decodes exactly one typed value. Trailing or truncated bytes are rejected.
  """
  @spec decode(data_type(), binary()) :: {:ok, scalar_value()} | {:error, Error.t()}
  def decode(:bit, <<0>>), do: {:ok, false}
  def decode(:bit, <<1>>), do: {:ok, true}
  def decode(type, <<value>>) when type in [:byte, :usint], do: {:ok, value}
  def decode(:sint, <<value::signed-big-8>>), do: {:ok, value}
  def decode(type, <<value::unsigned-big-16>>) when type in [:word, :uint], do: {:ok, value}

  def decode(type, <<value::unsigned-big-32>>) when type in [:dword, :udint],
    do: {:ok, value}

  def decode(type, <<value::unsigned-big-64>>) when type in [:lword, :ulint],
    do: {:ok, value}

  def decode(:int, <<value::signed-big-16>>), do: {:ok, value}
  def decode(:dint, <<value::signed-big-32>>), do: {:ok, value}
  def decode(:lint, <<value::signed-big-64>>), do: {:ok, value}
  def decode(:real, <<value::float-big-32>>), do: {:ok, value}
  def decode(:lreal, <<value::float-big-64>>), do: {:ok, value}
  def decode(:char, <<value>>), do: {:ok, <<value>>}

  def decode(:wchar, <<_value::binary-size(2)>> = binary) do
    case utf16_decode(binary) do
      {:ok, value} -> {:ok, value}
      :error -> malformed(:wchar, binary)
    end
  end

  def decode(:date, <<days::unsigned-big-16>> = binary) do
    date = Date.add(@date_epoch, days)

    if Date.compare(date, @date_maximum) in [:eq, :lt],
      do: {:ok, date},
      else: malformed(:date, binary)
  end

  def decode(:time, <<value::signed-big-32>>), do: {:ok, value}

  def decode(:time_of_day, <<milliseconds::unsigned-big-32>> = binary) do
    case milliseconds_to_time(milliseconds) do
      {:ok, value} -> {:ok, value}
      :error -> malformed(:time_of_day, binary)
    end
  end

  def decode(:date_and_time, <<_value::binary-size(8)>> = binary) do
    case decode_date_and_time(binary) do
      {:ok, value} -> {:ok, value}
      :error -> malformed(:date_and_time, binary)
    end
  end

  def decode(type, <<_value::binary-size(2)>> = binary) when type in [:s5time, :timer] do
    case decode_s5time(binary) do
      {:ok, value} -> {:ok, value}
      :error -> malformed(type, binary)
    end
  end

  def decode(:counter, <<value::unsigned-big-16>> = binary) do
    case decode_bcd(value, 3) do
      {:ok, count} when count <= 999 -> {:ok, count}
      _other -> malformed(:counter, binary)
    end
  end

  def decode({:string, maximum_length} = type, binary)
      when maximum_length in 1..@maximum_string_length and is_binary(binary) do
    case binary do
      <<^maximum_length, current_length, storage::binary-size(^maximum_length)>>
      when current_length <= maximum_length ->
        <<value::binary-size(^current_length), _padding::binary>> = storage
        {:ok, value}

      _other ->
        malformed(type, binary)
    end
  end

  def decode({:wstring, maximum_length} = type, binary)
      when maximum_length in 1..@maximum_wstring_length and is_binary(binary) do
    case binary do
      <<^maximum_length::unsigned-big-16, current_length::unsigned-big-16,
        storage::binary-size(^maximum_length * 2)>>
      when current_length <= maximum_length ->
        <<encoded::binary-size(^current_length * 2), _padding::binary>> = storage

        case utf16_decode(encoded) do
          {:ok, value} -> {:ok, value}
          :error -> malformed(type, binary)
        end

      _other ->
        malformed(type, binary)
    end
  end

  def decode(data_type, binary) do
    if supported_type?(data_type) do
      malformed(data_type, binary)
    else
      unsupported(:decode, data_type)
    end
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

  def decode(data_type, binary, count) do
    if supported_type?(data_type) do
      decode_counted(data_type, binary, count)
    else
      unsupported(:decode, data_type)
    end
  end

  @doc """
  Returns the fixed encoded size of one semantic value.
  """
  @spec size(data_type()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def size(type) when type in [:bit, :byte, :sint, :usint, :char], do: {:ok, 1}

  def size(type)
      when type in [:word, :uint, :int, :wchar, :date, :s5time, :counter, :timer],
      do: {:ok, 2}

  def size(type)
      when type in [:dword, :udint, :dint, :real, :time, :time_of_day],
      do: {:ok, 4}

  def size(type) when type in [:lword, :lint, :ulint, :lreal, :date_and_time], do: {:ok, 8}

  def size({:string, maximum_length}) when maximum_length in 1..@maximum_string_length,
    do: {:ok, maximum_length + 2}

  def size({:wstring, maximum_length}) when maximum_length in 1..@maximum_wstring_length,
    do: {:ok, maximum_length * 2 + 4}

  def size(data_type), do: unsupported(:size, data_type)

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

  defp supported_type?(type) when type in @atom_data_types, do: true

  defp supported_type?({:string, maximum_length}),
    do: maximum_length in 1..@maximum_string_length

  defp supported_type?({:wstring, maximum_length}),
    do: maximum_length in 1..@maximum_wstring_length

  defp supported_type?(_type), do: false

  defp encode_counted(data_type, _value, count)
       when not is_integer(count) or count not in 1..0xFFFF do
    {:error,
     Error.new(:data, :encode, :invalid_count, details: %{data_type: data_type, count: count})}
  end

  defp encode_counted(data_type, values, count) when is_list(values) do
    if length(values) == count do
      encode_values(data_type, values)
    else
      count_mismatch(:encode, count, length(values))
    end
  end

  defp encode_counted(_data_type, value, count) do
    {:error,
     Error.new(:data, :encode, :value_count_mismatch, details: %{count: count, value: value})}
  end

  defp decode_counted(data_type, _binary, count)
       when not is_integer(count) or count not in 1..0xFFFF do
    {:error,
     Error.new(:data, :decode, :invalid_count, details: %{data_type: data_type, count: count})}
  end

  defp decode_counted(data_type, binary, count) when is_binary(binary) do
    with {:ok, expected_size} <- encoded_size(data_type, count),
         :ok <- validate_binary_size(:decode, binary, expected_size),
         {:ok, element_size} <- size(data_type) do
      decode_values(data_type, binary, element_size, [])
    end
  end

  defp decode_counted(data_type, binary, count), do: malformed(data_type, binary, count)

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
    <<element::binary-size(^element_size), remaining::binary>> = binary

    case decode(data_type, element) do
      {:ok, value} -> decode_values(data_type, remaining, element_size, [value | values])
      {:error, %Error{} = error} -> {:error, add_index(error, length(values))}
    end
  end

  defp encode_date_and_time(%NaiveDateTime{} = value) do
    year = value.year
    {microseconds, _precision} = value.microsecond
    milliseconds = div(microseconds, 1_000)

    if year in 1990..2089 and rem(microseconds, 1_000) == 0 do
      short_year = if year >= 2000, do: year - 2000, else: year - 1900
      weekday = siemens_weekday(value)

      {:ok,
       <<encode_bcd(short_year, 2), encode_bcd(value.month, 2), encode_bcd(value.day, 2),
         encode_bcd(value.hour, 2), encode_bcd(value.minute, 2), encode_bcd(value.second, 2),
         encode_bcd(div(milliseconds, 10), 2), rem(milliseconds, 10) <<< 4 ||| weekday>>}
    else
      :error
    end
  end

  defp decode_date_and_time(
         <<year_bcd, month_bcd, day_bcd, hour_bcd, minute_bcd, second_bcd, ms_bcd, ms_weekday>>
       ) do
    with {:ok, short_year} <- decode_bcd(year_bcd, 2),
         {:ok, month} <- decode_bcd(month_bcd, 2),
         {:ok, day} <- decode_bcd(day_bcd, 2),
         {:ok, hour} <- decode_bcd(hour_bcd, 2),
         {:ok, minute} <- decode_bcd(minute_bcd, 2),
         {:ok, second} <- decode_bcd(second_bcd, 2),
         {:ok, milliseconds_high} <- decode_bcd(ms_bcd, 2),
         milliseconds_low when milliseconds_low in 0..9 <- ms_weekday >>> 4,
         weekday when weekday in 1..7 <- ms_weekday &&& 0x0F,
         year = if(short_year < 90, do: 2000 + short_year, else: 1900 + short_year),
         {:ok, date} <- Date.new(year, month, day),
         true <- weekday == siemens_weekday(date),
         milliseconds = milliseconds_high * 10 + milliseconds_low,
         true <- milliseconds <= 999,
         {:ok, time} <- Time.new(hour, minute, second, {milliseconds * 1_000, 3}),
         {:ok, date_time} <- NaiveDateTime.new(date, time) do
      {:ok, date_time}
    else
      _other -> :error
    end
  end

  defp encode_s5time(milliseconds) when milliseconds in 0..9_990_000 do
    [{0, 10}, {1, 100}, {2, 1_000}, {3, 10_000}]
    |> Enum.find_value(:error, fn {base_code, base} ->
      value = div(milliseconds, base)

      if rem(milliseconds, base) == 0 and value <= 999 do
        {:ok, <<base_code <<< 12 ||| encode_bcd(value, 3)::unsigned-big-16>>}
      end
    end)
  end

  defp encode_s5time(_milliseconds), do: :error

  defp decode_s5time(<<value::unsigned-big-16>>) do
    base = 10 * integer_power(10, value >>> 12)

    with {:ok, magnitude} <- decode_bcd(value &&& 0x0FFF, 3) do
      {:ok, magnitude * base}
    end
  end

  defp time_to_milliseconds(%Time{microsecond: {microseconds, _precision}} = value) do
    if rem(microseconds, 1_000) == 0 do
      milliseconds =
        ((value.hour * 60 + value.minute) * 60 + value.second) * 1_000 +
          div(microseconds, 1_000)

      {:ok, milliseconds}
    else
      :error
    end
  end

  defp milliseconds_to_time(milliseconds)
       when milliseconds in 0..(@milliseconds_per_day - 1)//1 do
    seconds = div(milliseconds, 1_000)
    millisecond = rem(milliseconds, 1_000)
    hour = div(seconds, 3_600)
    minute = div(rem(seconds, 3_600), 60)
    second = rem(seconds, 60)
    Time.new(hour, minute, second, {millisecond * 1_000, 3})
  end

  defp milliseconds_to_time(_milliseconds), do: :error

  defp siemens_weekday(%NaiveDateTime{} = value),
    do: siemens_weekday(NaiveDateTime.to_date(value))

  defp siemens_weekday(%Date{} = value), do: rem(Date.day_of_week(value), 7) + 1

  defp encode_bcd(value, digits) do
    Enum.reduce(0..(digits - 1), 0, fn position, encoded ->
      digit = value |> div(integer_power(10, position)) |> rem(10)
      encoded ||| digit <<< (position * 4)
    end)
  end

  defp decode_bcd(value, digits) do
    Enum.reduce_while(0..(digits - 1), {:ok, 0}, fn position, {:ok, decoded} ->
      digit = value >>> (position * 4) &&& 0x0F

      if digit <= 9 do
        {:cont, {:ok, decoded + digit * integer_power(10, position)}}
      else
        {:halt, :error}
      end
    end)
  end

  defp integer_power(_base, 0), do: 1

  defp integer_power(base, exponent),
    do: Enum.reduce(1..exponent, 1, fn _, value -> value * base end)

  defp utf16_encode(value) do
    case :unicode.characters_to_binary(value, :utf8, {:utf16, :big}) do
      encoded when is_binary(encoded) -> {:ok, encoded}
      _other -> :error
    end
  rescue
    _error -> :error
  end

  defp utf16_decode(value) do
    case :unicode.characters_to_binary(value, {:utf16, :big}, :utf8) do
      decoded when is_binary(decoded) -> {:ok, decoded}
      _other -> :error
    end
  rescue
    _error -> :error
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

  defp invalid(data_type, value, _error \\ nil) do
    {:error,
     Error.new(:data, :encode, :value_out_of_range,
       details: %{data_type: data_type, value: value}
     )}
  end

  defp malformed(data_type, binary, count \\ nil) do
    details = %{data_type: data_type, byte_size: byte_size_if_binary(binary)}
    details = if count, do: Map.put(details, :count, count), else: details
    {:error, Error.new(:data, :decode, :malformed_value, details: details)}
  end

  defp unsupported(operation, data_type) do
    {:error,
     Error.new(:data, operation, :data_type_not_supported, details: %{data_type: data_type})}
  end

  defp add_index(error, index), do: %{error | details: Map.put(error.details, :index, index)}

  defp byte_size_if_binary(binary) when is_binary(binary), do: byte_size(binary)
  defp byte_size_if_binary(_other), do: nil
end
