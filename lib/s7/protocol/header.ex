defmodule S7.Protocol.Header do
  @moduledoc """
  Codec for the generic classic S7comm header.
  """

  @protocol_id 0x32
  @rosctr_codes %{job: 0x01, ack: 0x02, ack_data: 0x03, userdata: 0x07}
  @code_to_rosctr Map.new(@rosctr_codes, fn {name, code} -> {code, name} end)

  @enforce_keys [:rosctr, :pdu_reference, :parameter_length, :data_length]
  defstruct [
    :rosctr,
    :pdu_reference,
    :parameter_length,
    :data_length,
    error_class: nil,
    error_code: nil
  ]

  @type rosctr :: :job | :ack | :ack_data | :userdata
  @type t :: %__MODULE__{
          rosctr: rosctr(),
          pdu_reference: 0..0xFFFF,
          parameter_length: 0..0xFFFF,
          data_length: 0..0xFFFF,
          error_class: byte() | nil,
          error_code: byte() | nil
        }

  @type decode_error :: :invalid_s7_pdu | :invalid_protocol_id | :unsupported_rosctr

  @doc """
  Encodes one S7 header.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = header) do
    rosctr = Map.fetch!(@rosctr_codes, header.rosctr)
    validate_word!(header.pdu_reference, :pdu_reference)
    validate_word!(header.parameter_length, :parameter_length)
    validate_word!(header.data_length, :data_length)

    base =
      <<@protocol_id, rosctr, 0::16, header.pdu_reference::unsigned-big-16,
        header.parameter_length::unsigned-big-16, header.data_length::unsigned-big-16>>

    case header.rosctr do
      rosctr when rosctr in [:ack, :ack_data] ->
        error_class = header.error_class || 0
        error_code = header.error_code || 0
        validate_byte!(error_class, :error_class)
        validate_byte!(error_code, :error_code)
        <<base::binary, error_class, error_code>>

      _other ->
        base
    end
  end

  @doc """
  Decodes one S7 header and returns the unconsumed service bytes.
  """
  @spec decode(binary()) ::
          {:ok, t(), binary()} | {:more, pos_integer()} | {:error, decode_error()}
  def decode(binary) when is_binary(binary) and byte_size(binary) < 2,
    do: {:more, 2 - byte_size(binary)}

  def decode(<<protocol_id, rosctr_code, _rest::binary>> = binary) do
    with :ok <- validate_protocol_id(protocol_id),
         {:ok, rosctr} <- decode_rosctr(rosctr_code) do
      decode_header(binary, rosctr)
    end
  end

  def decode(_binary), do: {:error, :invalid_s7_pdu}

  defp decode_header(binary, rosctr) when rosctr in [:ack, :ack_data] do
    if byte_size(binary) < 12 do
      {:more, 12 - byte_size(binary)}
    else
      <<@protocol_id, _rosctr, _reserved::16, reference::unsigned-big-16,
        parameter_length::unsigned-big-16, data_length::unsigned-big-16, error_class, error_code,
        remaining::binary>> = binary

      {:ok,
       %__MODULE__{
         rosctr: rosctr,
         pdu_reference: reference,
         parameter_length: parameter_length,
         data_length: data_length,
         error_class: error_class,
         error_code: error_code
       }, remaining}
    end
  end

  defp decode_header(binary, rosctr) do
    if byte_size(binary) < 10 do
      {:more, 10 - byte_size(binary)}
    else
      <<@protocol_id, _rosctr, _reserved::16, reference::unsigned-big-16,
        parameter_length::unsigned-big-16, data_length::unsigned-big-16, remaining::binary>> =
        binary

      {:ok,
       %__MODULE__{
         rosctr: rosctr,
         pdu_reference: reference,
         parameter_length: parameter_length,
         data_length: data_length
       }, remaining}
    end
  end

  defp validate_protocol_id(@protocol_id), do: :ok
  defp validate_protocol_id(_protocol_id), do: {:error, :invalid_protocol_id}

  defp decode_rosctr(code) do
    case @code_to_rosctr do
      %{^code => rosctr} -> {:ok, rosctr}
      _ -> {:error, :unsupported_rosctr}
    end
  end

  defp validate_word!(value, _field) when value in 0..0xFFFF, do: :ok
  defp validate_word!(_value, field), do: raise(ArgumentError, "invalid #{field}")

  defp validate_byte!(value, _field) when value in 0..0xFF, do: :ok
  defp validate_byte!(_value, field), do: raise(ArgumentError, "invalid #{field}")
end
