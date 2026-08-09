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
