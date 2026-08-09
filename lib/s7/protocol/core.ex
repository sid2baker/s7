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

  @type decode_error ::
          :invalid_s7_pdu | :invalid_protocol_id | :invalid_reserved_field | :unsupported_rosctr

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
      <<@protocol_id, _rosctr, reserved::16, reference::unsigned-big-16,
        parameter_length::unsigned-big-16, data_length::unsigned-big-16, error_class, error_code,
        remaining::binary>> = binary

      if reserved == 0 do
        {:ok,
         %__MODULE__{
           rosctr: rosctr,
           pdu_reference: reference,
           parameter_length: parameter_length,
           data_length: data_length,
           error_class: error_class,
           error_code: error_code
         }, remaining}
      else
        {:error, :invalid_reserved_field}
      end
    end
  end

  defp decode_header(binary, rosctr) do
    if byte_size(binary) < 10 do
      {:more, 10 - byte_size(binary)}
    else
      <<@protocol_id, _rosctr, reserved::16, reference::unsigned-big-16,
        parameter_length::unsigned-big-16, data_length::unsigned-big-16, remaining::binary>> =
        binary

      if reserved == 0 do
        {:ok,
         %__MODULE__{
           rosctr: rosctr,
           pdu_reference: reference,
           parameter_length: parameter_length,
           data_length: data_length
         }, remaining}
      else
        {:error, :invalid_reserved_field}
      end
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

defmodule S7.Protocol.PDU do
  @moduledoc "A generic S7 PDU with opaque parameter and data fields."

  alias S7.Protocol.Header

  @enforce_keys [:header, :parameters, :data]
  defstruct [:header, :parameters, :data]

  @type t :: %__MODULE__{header: Header.t(), parameters: binary(), data: binary()}
  @type decode_error :: Header.decode_error() | :invalid_s7_pdu

  @doc "Creates a PDU and derives its header lengths from the supplied fields."
  @spec new(Header.rosctr(), 0..0xFFFF, binary(), binary(), keyword()) :: t()
  def new(rosctr, reference, parameters, data \\ <<>>, opts \\ [])
      when is_binary(parameters) and is_binary(data) do
    %__MODULE__{
      header: %Header{
        rosctr: rosctr,
        pdu_reference: reference,
        parameter_length: byte_size(parameters),
        data_length: byte_size(data),
        error_class: Keyword.get(opts, :error_class),
        error_code: Keyword.get(opts, :error_code)
      },
      parameters: parameters,
      data: data
    }
  end

  @doc "Encodes a PDU as iodata. Header lengths are always recalculated."
  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{header: header, parameters: parameters, data: data})
      when is_binary(parameters) and is_binary(data) do
    header = %{
      header
      | parameter_length: byte_size(parameters),
        data_length: byte_size(data)
    }

    [Header.encode(header), parameters, data]
  end

  def encode(_pdu), do: raise(ArgumentError, "invalid S7 PDU")

  @doc "Decodes one PDU and leaves bytes following its declared data field."
  @spec decode(binary()) ::
          {:ok, t(), binary()} | {:more, pos_integer()} | {:error, decode_error()}
  def decode(binary) when is_binary(binary) do
    with {:ok, header, payload} <- Header.decode(binary) do
      decode_fields(header, payload)
    end
  end

  def decode(_binary), do: {:error, :invalid_s7_pdu}

  @doc false
  @spec encoded_size(t()) :: pos_integer()
  def encoded_size(%__MODULE__{} = pdu), do: IO.iodata_length(encode(pdu))

  defp decode_fields(header, payload) do
    parameter_length = header.parameter_length
    data_length = header.data_length
    expected = parameter_length + data_length

    if byte_size(payload) < expected do
      {:more, expected - byte_size(payload)}
    else
      <<parameters::binary-size(^parameter_length), data::binary-size(^data_length),
        remaining::binary>> = payload

      {:ok, %__MODULE__{header: header, parameters: parameters, data: data}, remaining}
    end
  end
end

defmodule S7.Protocol.Job do
  @moduledoc false

  import Bitwise

  alias S7.Error
  alias S7.Protocol.PDU

  @complete_rejections [
    :access_denied,
    :object_not_found,
    :invalid_block,
    :resource_busy,
    :operation_not_supported,
    :plc_error
  ]

  @spec validate_response_header(PDU.t(), atom()) :: :ok | {:error, Error.t()}
  def validate_response_header(%PDU{header: header}, operation) do
    code = (header.error_class || 0) <<< 8 ||| (header.error_code || 0)

    cond do
      code != 0 -> plc_error(operation, code)
      header.rosctr != :ack_data -> malformed(operation, %{rosctr: header.rosctr})
      true -> :ok
    end
  end

  @spec complete_rejection?(Error.t()) :: boolean()
  def complete_rejection?(%Error{reason: reason}), do: reason in @complete_rejections

  @spec plc_error(atom(), 0..0xFFFF) :: {:error, Error.t()}
  def plc_error(operation, code) do
    reason =
      case code do
        0xD241 -> :access_denied
        value when value in [0xD209, 0xD20E] -> :object_not_found
        value when value in [0xD20C, 0xD20D, 0xD210, 0xD212, 0xD219, 0xD220] -> :invalid_block
        value when value in [0xD2A1, 0xD2A4] -> :resource_busy
        value when value in [0xD201, 0xD202, 0xD2C2] -> :operation_not_supported
        _other -> :plc_error
      end

    {:error, Error.new(:s7, operation, reason, code: code)}
  end

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
