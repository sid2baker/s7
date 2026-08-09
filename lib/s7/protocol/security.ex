defmodule S7.Protocol.Security do
  @moduledoc """
  Pure codec for classic session-password authentication and logout.

  This exchange changes access authorization only. It provides neither
  encryption nor peer authentication.
  """

  import Bitwise

  alias S7.{Error, SessionPassword}
  alias S7.Protocol.{PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}

  @login 0x01
  @logout 0x02
  @null 0x00
  @empty 0x0A

  @doc false
  @spec login_request(term()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def login_request(password) do
    with {:ok, padded} <- SessionPassword.validate_and_pad(password) do
      UserData.request(:security, @login, encode_padded_password(padded))
    end
  end

  @doc false
  @spec logout_request() :: {:ok, UserData.t()} | {:error, Error.t()}
  def logout_request do
    UserData.request(:security, @logout, <<>>, return_code: @empty, transport_size: @null)
  end

  @doc false
  @spec encode_password(SessionPassword.t()) :: binary()
  def encode_password(password) do
    password |> SessionPassword.padded() |> encode_padded_password()
  end

  defp encode_padded_password(padded) do
    <<first, second, rest::binary-size(6)>> = padded
    first = bxor(first, 0x55)
    second = bxor(second, 0x55)
    encode_rest(rest, first, second, [second, first])
  end

  @doc false
  @spec decode_response(PDU.t(), UserData.t(), 0..0xFFFF) ::
          {:ok, :ok} | {:error, Error.t()}
  def decode_response(pdu, request, reference) do
    case UserData.decode_response(pdu, request, reference, allow_null_success: true) do
      {:ok, response} -> validate_response(response)
      {:error, %Error{} = error} -> {:error, translate_error(error, request)}
    end
  end

  defp encode_rest(<<>>, _previous_two, _previous, encoded),
    do: encoded |> Enum.reverse() |> :binary.list_to_bin()

  defp encode_rest(<<plain, rest::binary>>, previous_two, previous, encoded) do
    byte = plain |> bxor(0x55) |> bxor(previous_two)
    encode_rest(rest, previous, byte, [byte | encoded])
  end

  defp validate_response(%UserData{
         parameter: %Parameter{
           data_unit_reference: data_unit_reference,
           last_data_unit: 0,
           error_code: 0
         },
         payload: %Payload{return_code: @empty, transport_size: @null, data: <<>>}
       })
       when data_unit_reference in 0..0xFF,
       do: {:ok, :ok}

  defp validate_response(_response),
    do: {:error, Error.new(:s7, :authenticate, :malformed_response)}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD241} = error, _request),
    do: %{error | reason: :access_denied}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD602} = error, _request),
    do: %{error | reason: :invalid_password}

  defp translate_error(
         %Error{reason: :userdata_error, code: 0xD604} = error,
         %UserData{parameter: %Parameter{subfunction: @login}}
       ),
       do: %{error | reason: :already_authenticated}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD604} = error, _request),
    do: %{error | reason: :not_authenticated}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD605} = error, _request),
    do: %{error | reason: :password_not_configured}

  defp translate_error(error, _request), do: error
end
