defmodule S7.Transport.COTP do
  @moduledoc """
  Codec for the COTP subset used by the S7 client.

  Connection parameters are represented explicitly. The decoder accepts them
  in any TLV order and retains unknown parameters for diagnostics.
  """

  import Bitwise

  alias S7.Transport.COTP.{ConnectionConfirm, ConnectionRequest, Data}

  @connection_request 0xE0
  @connection_confirm 0xD0
  @data 0xF0

  @tpdu_size_codes %{
    128 => 0x07,
    256 => 0x08,
    512 => 0x09,
    1024 => 0x0A,
    2048 => 0x0B,
    4096 => 0x0C,
    8192 => 0x0D
  }

  @code_to_tpdu_size Map.new(@tpdu_size_codes, fn {size, code} -> {code, size} end)

  @type t :: ConnectionRequest.t() | ConnectionConfirm.t() | Data.t()
  @type decode_error ::
          :invalid_cotp
          | :invalid_header_length
          | :unsupported_tpdu
          | :malformed_parameters
          | :invalid_tpdu_size
          | :unexpected_payload

  @doc """
  Encodes one supported TPDU as iodata.
  """
  @spec encode(t()) :: iodata()
  def encode(%ConnectionRequest{} = request),
    do: encode_connection(@connection_request, request)

  def encode(%ConnectionConfirm{} = confirm),
    do: encode_connection(@connection_confirm, confirm)

  def encode(%Data{payload: payload, eot: eot, tpdu_number: number})
      when is_binary(payload) and is_boolean(eot) and number in 0..0x7F do
    eot_number = if eot, do: 0x80 ||| number, else: number
    [<<2, @data, eot_number>>, payload]
  end

  def encode(_tpdu), do: raise(ArgumentError, "invalid COTP TPDU")

  @doc """
  Decodes a TPDU contained by one TPKT frame.
  """
  @spec decode(binary()) :: {:ok, t()} | {:more, pos_integer()} | {:error, decode_error()}
  def decode(binary) when is_binary(binary) and byte_size(binary) < 2,
    do: {:more, 2 - byte_size(binary)}

  def decode(<<length, type, rest::binary>>) do
    required = length - 1

    cond do
      length < 1 ->
        {:error, :invalid_header_length}

      byte_size(rest) < required ->
        {:more, required - byte_size(rest)}

      type == @data ->
        decode_data(length, rest)

      type in [@connection_request, @connection_confirm] ->
        decode_connection(length, type, rest)

      true ->
        {:error, :unsupported_tpdu}
    end
  end

  def decode(_binary), do: {:error, :invalid_cotp}

  @doc false
  @spec valid_tpdu_size?(term()) :: boolean()
  def valid_tpdu_size?(size), do: Map.has_key?(@tpdu_size_codes, size)

  defp encode_connection(type, connection) do
    validate_connection!(type, connection)
    validate_reference!(connection.destination_reference)
    validate_reference!(connection.source_reference)
    validate_byte!(connection.class_option)

    parameters = encode_parameters(connection)
    length = 6 + IO.iodata_length(parameters)

    if length > 0xFF do
      raise ArgumentError, "COTP connection header is too large"
    end

    [
      <<length, type, connection.destination_reference::unsigned-big-16,
        connection.source_reference::unsigned-big-16, connection.class_option>>,
      parameters
    ]
  end

  defp encode_parameters(connection) do
    parameters = [
      encode_parameter(0xC1, connection.src_tsap),
      encode_parameter(0xC2, connection.dst_tsap),
      encode_tpdu_size(connection.tpdu_size)
    ]

    unknown =
      Enum.map(connection.unknown_parameters, fn {code, value} ->
        encode_parameter(code, value)
      end)

    [parameters, unknown]
  end

  defp encode_parameter(_code, nil), do: []

  defp encode_parameter(code, value)
       when is_integer(code) and code in 0..0xFF and is_binary(value) and
              byte_size(value) in 1..16 do
    [<<code, byte_size(value)>>, value]
  end

  defp encode_parameter(_code, _value), do: raise(ArgumentError, "invalid COTP parameter")

  defp encode_tpdu_size(nil), do: []

  defp encode_tpdu_size(size) do
    case @tpdu_size_codes do
      %{^size => code} -> <<0xC0, 1, code>>
      _ -> raise ArgumentError, "unsupported COTP TPDU size: #{inspect(size)}"
    end
  end

  defp decode_data(2, <<eot_number, payload::binary>>) do
    {:ok,
     %Data{
       payload: payload,
       eot: (eot_number &&& 0x80) != 0,
       tpdu_number: eot_number &&& 0x7F
     }}
  end

  defp decode_data(_length, _rest), do: {:error, :invalid_header_length}

  defp decode_connection(length, type, rest) when length >= 6 do
    parameter_size = length - 6

    case rest do
      <<destination_reference::unsigned-big-16, source_reference::unsigned-big-16, class_option,
        parameters::binary-size(parameter_size)>> ->
        with {:ok, decoded} <- decode_parameters(parameters) do
          fields =
            Map.merge(decoded, %{
              destination_reference: destination_reference,
              source_reference: source_reference,
              class_option: class_option
            })

          connection_struct(type, fields)
        end

      _ ->
        {:error, :unexpected_payload}
    end
  end

  defp decode_connection(_length, _type, _rest), do: {:error, :invalid_header_length}

  defp decode_parameters(parameters) do
    initial = %{src_tsap: nil, dst_tsap: nil, tpdu_size: nil, unknown_parameters: []}
    decode_parameters(parameters, initial)
  end

  defp decode_parameters(<<>>, decoded) do
    {:ok, %{decoded | unknown_parameters: Enum.reverse(decoded.unknown_parameters)}}
  end

  defp decode_parameters(<<code, length, rest::binary>>, decoded)
       when byte_size(rest) >= length do
    <<value::binary-size(length), remaining::binary>> = rest

    with {:ok, decoded} <- put_parameter(decoded, code, value) do
      decode_parameters(remaining, decoded)
    end
  end

  defp decode_parameters(_parameters, _decoded), do: {:error, :malformed_parameters}

  defp put_parameter(decoded, 0xC0, <<code>>) do
    case @code_to_tpdu_size do
      %{^code => size} -> put_unique(decoded, :tpdu_size, size)
      _ -> {:error, :invalid_tpdu_size}
    end
  end

  defp put_parameter(_decoded, 0xC0, _value), do: {:error, :malformed_parameters}
  defp put_parameter(decoded, 0xC1, value), do: put_unique(decoded, :src_tsap, value)
  defp put_parameter(decoded, 0xC2, value), do: put_unique(decoded, :dst_tsap, value)

  defp put_parameter(decoded, code, value) do
    {:ok, %{decoded | unknown_parameters: [{code, value} | decoded.unknown_parameters]}}
  end

  defp put_unique(decoded, key, value) do
    case Map.fetch!(decoded, key) do
      nil -> {:ok, Map.put(decoded, key, value)}
      _existing -> {:error, :malformed_parameters}
    end
  end

  defp connection_struct(@connection_request, fields) do
    if is_binary(fields.src_tsap) and is_binary(fields.dst_tsap) and
         is_integer(fields.tpdu_size) do
      {:ok, struct!(ConnectionRequest, fields)}
    else
      {:error, :malformed_parameters}
    end
  end

  defp connection_struct(@connection_confirm, fields),
    do: {:ok, struct!(ConnectionConfirm, fields)}

  defp validate_connection!(@connection_request, connection) do
    if is_binary(connection.src_tsap) and is_binary(connection.dst_tsap) and
         is_integer(connection.tpdu_size) do
      :ok
    else
      raise ArgumentError,
            "COTP Connection Request requires source/destination TSAP and TPDU size"
    end
  end

  defp validate_connection!(@connection_confirm, _connection), do: :ok

  defp validate_reference!(reference) when reference in 0..0xFFFF, do: :ok
  defp validate_reference!(_reference), do: raise(ArgumentError, "invalid COTP reference")

  defp validate_byte!(value) when value in 0..0xFF, do: :ok
  defp validate_byte!(_value), do: raise(ArgumentError, "invalid COTP class/option byte")
end
