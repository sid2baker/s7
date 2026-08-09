defmodule S7.Block do
  @moduledoc """
  Identity and wire-code helpers for one classic PLC program block.

  Known block types use atoms. Decoders preserve unknown peer values as
  `{:unknown, code}` without creating atoms.
  """

  alias S7.Error

  @type_codes %{
    ob: 0x3038,
    cmod: 0x3039,
    db: 0x3041,
    sdb: 0x3042,
    fc: 0x3043,
    sfc: 0x3044,
    fb: 0x3045,
    sfb: 0x3046
  }
  @subtype_codes %{ob: 0x08, db: 0x0A, sdb: 0x0B, fc: 0x0C, sfc: 0x0D, fb: 0x0E, sfb: 0x0F}
  @language_codes %{
    0x00 => :undefined,
    0x01 => :awl,
    0x02 => :kop,
    0x03 => :fup,
    0x04 => :scl,
    0x05 => :db,
    0x06 => :graph,
    0x07 => :sdb,
    0x08 => :cpu_db,
    0x11 => :sdb_after_reset,
    0x12 => :sdb_routing,
    0x29 => :encrypted
  }
  @code_to_type Map.new(@type_codes, fn {type, code} -> {code, type} end)
  @code_to_subtype Map.new(@subtype_codes, fn {type, code} -> {code, type} end)
  @default_max_bytes 1_048_576
  @default_max_fragments 64
  @maximum_bytes 16_777_216
  @maximum_fragments 4096

  @enforce_keys [:type, :number]
  defstruct [:type, :number]

  @type known_type :: :ob | :cmod | :db | :sdb | :fc | :sfc | :fb | :sfb
  @type decoded_type :: known_type() | {:unknown, 0..0xFFFF}
  @type language ::
          :undefined
          | :awl
          | :kop
          | :fup
          | :scl
          | :db
          | :graph
          | :sdb
          | :cpu_db
          | :sdb_after_reset
          | :sdb_routing
          | :encrypted
          | {:unknown, byte()}
  @type t :: %__MODULE__{type: decoded_type(), number: 0..0xFFFF}
  @type limits :: %{max_bytes: pos_integer(), max_fragments: pos_integer()}

  @doc false
  @spec normalize(term(), term(), atom()) :: {:ok, t()} | {:error, Error.t()}
  def normalize(type, number, operation) when is_atom(type) and number in 0..0xFFFF do
    if Map.has_key?(@type_codes, type) do
      {:ok, %__MODULE__{type: type, number: number}}
    else
      invalid(operation, :type, type)
    end
  end

  def normalize(type, number, operation) do
    with {:ok, type} <- validate_request_type(type, operation),
         :ok <- validate_number(number, operation) do
      {:ok, %__MODULE__{type: type, number: number}}
    end
  end

  @doc false
  @spec validate(t(), atom()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{type: type, number: number}, operation),
    do: normalize(type, number, operation)

  def validate(block, operation), do: invalid(operation, :block, block)

  @doc false
  @spec validate_request_type(term(), atom()) :: {:ok, known_type()} | {:error, Error.t()}
  def validate_request_type(type, _operation) when is_map_key(@type_codes, type), do: {:ok, type}
  def validate_request_type(type, operation), do: invalid(operation, :type, type)

  @doc false
  @spec encode_type(known_type()) :: binary()
  def encode_type(type), do: <<Map.fetch!(@type_codes, type)::unsigned-big-16>>

  @doc false
  @spec decode_type(0..0xFFFF) :: decoded_type()
  def decode_type(code), do: Map.get(@code_to_type, code, {:unknown, code})

  @doc false
  @spec decode_subtype(byte()) :: decoded_type()
  def decode_subtype(code), do: Map.get(@code_to_subtype, code, {:unknown, code})

  @doc false
  @spec decode_language(byte()) :: language()
  def decode_language(code), do: Map.get(@language_codes, code, {:unknown, code})

  @doc false
  @spec validate_list_options(term(), atom()) :: {:ok, limits()} | {:error, Error.t()}
  def validate_list_options(opts, operation) when is_list(opts) do
    with :ok <- validate_keyword_options(opts, operation),
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

  def validate_list_options(opts, operation), do: invalid_options(operation, opts)

  defp validate_number(number, _operation) when number in 0..0xFFFF, do: :ok
  defp validate_number(number, operation), do: invalid(operation, :number, number)

  defp validate_keyword_options(opts, operation) do
    if Keyword.keyword?(opts) do
      case Enum.find(Keyword.keys(opts), &(&1 not in [:max_bytes, :max_fragments])) do
        nil ->
          :ok

        key ->
          {:error,
           Error.new(:client, operation, :invalid_option,
             details: %{option: key, value: Keyword.get(opts, key)}
           )}
      end
    else
      invalid_options(operation, opts)
    end
  end

  defp positive_option(opts, key, default, maximum, operation) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 and value <= maximum do
      {:ok, value}
    else
      {:error,
       Error.new(:client, operation, :invalid_option, details: %{option: key, value: value})}
    end
  end

  defp invalid_options(operation, opts),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}

  defp invalid(operation, field, value),
    do:
      {:error,
       Error.new(:client, operation, :invalid_block, details: %{field: field, value: value})}
end
