defmodule S7.SZL do
  @moduledoc """
  A decoded classic System Status List (SZL/SSL) result.

  Records remain raw because layouts vary by list ID, CPU family, and firmware.
  Typed metadata helpers decode only documented, stable record layouts.
  """

  import Bitwise

  alias S7.Error

  @default_max_bytes 1_048_576
  @default_max_fragments 64
  @maximum_bytes 16_777_216
  @maximum_fragments 4096
  @options [:max_bytes, :max_fragments]

  @enforce_keys [:id, :index, :record_length, :record_count, :records, :raw]
  defstruct [:id, :index, :record_length, :record_count, :records, :raw]

  @type t :: %__MODULE__{
          id: 0..0xFFFF,
          index: 0..0xFFFF,
          record_length: 0..0xFFFF,
          record_count: 0..0xFFFF,
          records: [binary()],
          raw: binary()
        }

  @type limits :: %{max_bytes: pos_integer(), max_fragments: pos_integer()}

  @doc false
  @spec validate_request(term(), term(), term(), atom()) ::
          {:ok, limits()} | {:error, Error.t()}
  def validate_request(id, index, opts, operation) do
    with :ok <- validate_word(id, :id, operation),
         :ok <- validate_word(index, :index, operation),
         :ok <- validate_options(opts, operation),
         {:ok, max_bytes} <-
           positive_option(opts, :max_bytes, @default_max_bytes, @maximum_bytes, operation),
         {:ok, max_fragments} <-
           positive_option(
             opts,
             :max_fragments,
             @default_max_fragments,
             @maximum_fragments,
             operation
           ) do
      {:ok, %{max_bytes: max_bytes, max_fragments: max_fragments}}
    end
  end

  @doc false
  @spec decode(0..0xFFFF, 0..0xFFFF, binary(), atom()) ::
          {:ok, t()} | {:error, Error.t()}
  def decode(id, index, raw, operation \\ :read_szl)

  def decode(id, index, raw, operation)
      when id in 0..0xFFFF and index in 0..0xFFFF and is_binary(raw) and byte_size(raw) >= 4 do
    <<record_length::unsigned-big-16, record_count::unsigned-big-16, data::binary>> = raw
    expected_size = record_length * record_count

    cond do
      record_count > 0 and record_length == 0 ->
        malformed(operation, %{record_length: record_length, record_count: record_count})

      byte_size(data) != expected_size ->
        malformed(operation, %{
          declared_record_bytes: expected_size,
          received_record_bytes: byte_size(data),
          record_length: record_length,
          record_count: record_count
        })

      true ->
        records = split_records(data, record_length, record_count, [])

        {:ok,
         %__MODULE__{
           id: id,
           index: index,
           record_length: record_length,
           record_count: record_count,
           records: records,
           raw: raw
         }}
    end
  end

  def decode(_id, _index, raw, operation) when is_binary(raw),
    do: malformed(operation, %{bytes_needed: max(4 - byte_size(raw), 0)})

  def decode(_id, _index, _raw, operation), do: malformed(operation, %{})

  @doc false
  @spec record_by_index(t(), 0..0xFFFF) :: {:ok, binary()} | :error
  def record_by_index(%__MODULE__{records: records}, index) when index in 0..0xFFFF do
    case Enum.find(records, fn
           <<^index::unsigned-big-16, _rest::binary>> -> true
           _record -> false
         end) do
      nil -> :error
      record -> {:ok, record}
    end
  end

  @doc false
  @spec sublist(t()) :: byte()
  def sublist(%__MODULE__{id: id}), do: id &&& 0xFF

  @doc false
  @spec malformed(atom(), map()) :: {:error, Error.t()}
  def malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}

  defp validate_word(value, _field, _operation) when value in 0..0xFFFF, do: :ok

  defp validate_word(value, field, operation) do
    {:error,
     Error.new(:client, operation, :invalid_szl_request, details: %{field: field, value: value})}
  end

  defp validate_options(opts, operation) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Enum.find(Keyword.keys(opts), &(&1 not in @options)) do
        nil -> :ok
        option -> invalid_option(operation, option, Keyword.get(opts, option))
      end
    else
      {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}
    end
  end

  defp validate_options(opts, operation),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}

  defp positive_option(opts, key, default, maximum, operation) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 and value <= maximum do
      {:ok, value}
    else
      invalid_option(operation, key, value)
    end
  end

  defp invalid_option(operation, option, value),
    do:
      {:error,
       Error.new(:client, operation, :invalid_option, details: %{option: option, value: value})}

  defp split_records(<<>>, _record_length, 0, records), do: Enum.reverse(records)

  defp split_records(data, record_length, count, records) do
    <<record::binary-size(record_length), remaining::binary>> = data
    split_records(remaining, record_length, count - 1, [record | records])
  end
end
