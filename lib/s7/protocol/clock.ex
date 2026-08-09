defmodule S7.Protocol.Clock do
  @moduledoc """
  Pure codec for classic read-clock and set-clock userdata services.

  Values are local PLC civil time. No timezone conversion is performed.
  """

  alias S7.{Data, Error, PLCClock}
  alias S7.Protocol.{PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}

  @read_clock 0x01
  @set_clock 0x02
  @octet_string 0x09
  @null 0x00
  @success 0xFF
  @empty 0x0A
  @set_century_hint 0x19

  @doc false
  @spec read_request() :: {:ok, UserData.t()} | {:error, Error.t()}
  def read_request do
    UserData.request(:time, @read_clock, <<>>, return_code: @empty, transport_size: @null)
  end

  @doc false
  @spec set_request(term()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def set_request(%NaiveDateTime{} = datetime) do
    with {:ok, timestamp} <- encode_timestamp(datetime) do
      UserData.request(:time, @set_clock, timestamp)
    end
  end

  def set_request(_datetime),
    do: {:error, Error.new(:client, :set_clock, :invalid_clock_value)}

  @doc false
  @spec decode_response(PDU.t(), UserData.t(), 0..0xFFFF, :read | :set) ::
          {:ok, PLCClock.t() | :ok} | {:error, Error.t()}
  def decode_response(pdu, request, reference, action) when action in [:read, :set] do
    with {:ok, response} <-
           UserData.decode_response(pdu, request, reference, allow_null_success: action == :set),
         :ok <- validate_complete(response.parameter) do
      decode_payload(response.payload, action)
    end
  end

  @doc false
  @spec encode_timestamp(NaiveDateTime.t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_timestamp(%NaiveDateTime{} = datetime) do
    case Data.encode(:date_and_time, datetime) do
      {:ok, encoded} -> {:ok, <<0, @set_century_hint, encoded::binary>>}
      {:error, %Error{}} -> {:error, Error.new(:client, :set_clock, :invalid_clock_value)}
    end
  end

  @doc false
  @spec decode_timestamp(binary()) :: {:ok, PLCClock.t()} | {:error, Error.t()}
  def decode_timestamp(<<reserved, century_hint, encoded::binary-size(8)>> = raw) do
    case Data.decode(:date_and_time, encoded) do
      {:ok, datetime} ->
        {:ok,
         %PLCClock{
           datetime: datetime,
           reserved: reserved,
           century_hint: century_hint,
           raw: raw
         }}

      {:error, %Error{} = error} ->
        malformed(%{codec_reason: error.reason})
    end
  end

  def decode_timestamp(raw) when is_binary(raw),
    do: malformed(%{expected_size: 10, received_size: byte_size(raw)})

  def decode_timestamp(_raw), do: malformed(%{})

  defp decode_payload(
         %Payload{return_code: @success, transport_size: @octet_string, data: data},
         :read
       ),
       do: decode_timestamp(data)

  defp decode_payload(%Payload{return_code: @empty, transport_size: @null, data: <<>>}, :set),
    do: {:ok, :ok}

  defp decode_payload(payload, _action),
    do:
      malformed(%{
        return_code: payload.return_code,
        transport_size: payload.transport_size,
        received_size: byte_size(payload.data)
      })

  defp validate_complete(%Parameter{
         data_unit_reference: data_unit_reference,
         last_data_unit: 0,
         error_code: 0
       })
       when data_unit_reference in 0..0xFF,
       do: :ok

  defp validate_complete(_parameter), do: malformed(%{parameter_extension: :invalid})

  defp malformed(details),
    do: {:error, Error.new(:s7, :clock, :malformed_response, details: details)}
end
