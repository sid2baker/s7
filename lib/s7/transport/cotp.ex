defmodule S7.Transport.COTP do
  @moduledoc """
  Codec for the COTP subset used by the S7 client.

  Connection parameters are represented explicitly. The decoder accepts them
  in any TLV order and retains unknown parameters for diagnostics.
  """

  import Bitwise

  alias S7.Transport.COTP.{
    ConnectionConfirm,
    ConnectionRequest,
    Data,
    DisconnectConfirm,
    DisconnectRequest,
    ErrorTPDU
  }

  @connection_request 0xE0
  @connection_confirm 0xD0
  @disconnect_request 0x80
  @disconnect_confirm 0xC0
  @error 0x70
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

  @type t ::
          ConnectionRequest.t()
          | ConnectionConfirm.t()
          | DisconnectRequest.t()
          | DisconnectConfirm.t()
          | ErrorTPDU.t()
          | Data.t()
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

  def encode(%DisconnectRequest{} = request), do: encode_disconnect_request(request)
  def encode(%DisconnectConfirm{} = confirm), do: encode_disconnect_confirm(confirm)
  def encode(%ErrorTPDU{} = error), do: encode_error(error)

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

      type == @disconnect_request ->
        decode_disconnect_request(length, rest)

      type == @disconnect_confirm ->
        decode_disconnect_confirm(length, rest)

      type == @error ->
        decode_error(length, rest)

      true ->
        {:error, :unsupported_tpdu}
    end
  end

  def decode(_binary), do: {:error, :invalid_cotp}

  @doc false
  @spec valid_tpdu_size?(term()) :: boolean()
  def valid_tpdu_size?(size), do: Map.has_key?(@tpdu_size_codes, size)

  @doc """
  Splits an S7 PDU into class-0 COTP Data TPDUs.

  The negotiated TPDU size includes the three-byte Data TPDU header. Class 0
  requires the TPDU number to remain zero for every fragment.
  """
  @spec segment_data(binary(), pos_integer()) ::
          {:ok, [Data.t()]} | {:error, :invalid_payload | :invalid_tpdu_size}
  def segment_data(payload, tpdu_size)
      when is_binary(payload) and is_map_key(@tpdu_size_codes, tpdu_size) do
    maximum_payload = tpdu_size - 3
    chunks = split_binary(payload, maximum_payload, [])
    last = length(chunks) - 1

    {:ok,
     chunks
     |> Enum.with_index()
     |> Enum.map(fn {chunk, index} ->
       %Data{payload: chunk, eot: index == last, tpdu_number: 0}
     end)}
  end

  def segment_data(payload, _tpdu_size) when not is_binary(payload),
    do: {:error, :invalid_payload}

  def segment_data(_payload, _tpdu_size), do: {:error, :invalid_tpdu_size}

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

    unknown = Enum.map(connection.unknown_parameters, &encode_unknown_parameter/1)

    [parameters, unknown]
  end

  defp encode_parameter(_code, nil), do: []

  defp encode_parameter(code, value)
       when is_integer(code) and code in 0..0xFF and is_binary(value) and
              byte_size(value) in 1..16 do
    [<<code, byte_size(value)>>, value]
  end

  defp encode_parameter(_code, _value), do: raise(ArgumentError, "invalid COTP parameter")

  defp encode_unknown_parameter({code, value})
       when is_integer(code) and code in 0..0xFF and is_binary(value) and
              byte_size(value) <= 0xFF do
    [<<code, byte_size(value)>>, value]
  end

  defp encode_unknown_parameter(_parameter),
    do: raise(ArgumentError, "invalid unknown COTP parameter")

  defp encode_disconnect_request(request) do
    validate_reference!(request.destination_reference)
    validate_reference!(request.source_reference)
    validate_byte!(request.reason)

    parameters = [
      encode_optional_parameter(0xE0, request.additional_information),
      Enum.map(request.unknown_parameters, &encode_unknown_parameter/1)
    ]

    encode_control_header(
      <<@disconnect_request, request.destination_reference::unsigned-big-16,
        request.source_reference::unsigned-big-16, request.reason>>,
      parameters
    )
  end

  defp encode_disconnect_confirm(confirm) do
    validate_reference!(confirm.destination_reference)
    validate_reference!(confirm.source_reference)
    parameters = Enum.map(confirm.unknown_parameters, &encode_unknown_parameter/1)

    encode_control_header(
      <<@disconnect_confirm, confirm.destination_reference::unsigned-big-16,
        confirm.source_reference::unsigned-big-16>>,
      parameters
    )
  end

  defp encode_error(error) do
    validate_reference!(error.destination_reference)
    validate_byte!(error.reject_cause)

    parameters = [
      encode_optional_parameter(0xC1, error.invalid_tpdu),
      Enum.map(error.unknown_parameters, &encode_unknown_parameter/1)
    ]

    encode_control_header(
      <<@error, error.destination_reference::unsigned-big-16, error.reject_cause>>,
      parameters
    )
  end

  defp encode_optional_parameter(_code, nil), do: []

  defp encode_optional_parameter(code, value)
       when is_binary(value) and byte_size(value) <= 0xFF,
       do: [<<code, byte_size(value)>>, value]

  defp encode_optional_parameter(_code, _value),
    do: raise(ArgumentError, "invalid COTP control parameter")

  defp encode_control_header(fixed, parameters) do
    length = byte_size(fixed) + IO.iodata_length(parameters)

    if length > 0xFF do
      raise ArgumentError, "COTP control header is too large"
    end

    [<<length>>, fixed, parameters]
  end

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

  defp decode_disconnect_request(length, rest) when length >= 6 do
    parameter_size = length - 6

    case rest do
      <<destination_reference::unsigned-big-16, source_reference::unsigned-big-16, reason,
        parameters::binary-size(parameter_size)>> ->
        with {:ok, decoded} <-
               decode_control_parameters(parameters, 0xE0, :additional_information) do
          {:ok,
           struct!(DisconnectRequest, %{
             destination_reference: destination_reference,
             source_reference: source_reference,
             reason: reason,
             additional_information: decoded.known,
             unknown_parameters: decoded.unknown
           })}
        end

      _ ->
        {:error, :unexpected_payload}
    end
  end

  defp decode_disconnect_request(_length, _rest), do: {:error, :invalid_header_length}

  defp decode_disconnect_confirm(length, rest) when length >= 5 do
    parameter_size = length - 5

    case rest do
      <<destination_reference::unsigned-big-16, source_reference::unsigned-big-16,
        parameters::binary-size(parameter_size)>> ->
        with {:ok, decoded} <- decode_control_parameters(parameters, nil, nil) do
          {:ok,
           %DisconnectConfirm{
             destination_reference: destination_reference,
             source_reference: source_reference,
             unknown_parameters: decoded.unknown
           }}
        end

      _ ->
        {:error, :unexpected_payload}
    end
  end

  defp decode_disconnect_confirm(_length, _rest), do: {:error, :invalid_header_length}

  defp decode_error(length, rest) when length >= 4 do
    parameter_size = length - 4

    case rest do
      <<destination_reference::unsigned-big-16, reject_cause,
        parameters::binary-size(parameter_size)>> ->
        with {:ok, decoded} <- decode_control_parameters(parameters, 0xC1, :invalid_tpdu) do
          {:ok,
           %ErrorTPDU{
             destination_reference: destination_reference,
             reject_cause: reject_cause,
             invalid_tpdu: decoded.known,
             unknown_parameters: decoded.unknown
           }}
        end

      _ ->
        {:error, :unexpected_payload}
    end
  end

  defp decode_error(_length, _rest), do: {:error, :invalid_header_length}

  defp decode_control_parameters(parameters, known_code, known_key) do
    decode_control_parameters(parameters, known_code, known_key, %{known: nil, unknown: []})
  end

  defp decode_control_parameters(<<>>, _known_code, _known_key, decoded) do
    {:ok, %{decoded | unknown: Enum.reverse(decoded.unknown)}}
  end

  defp decode_control_parameters(
         <<code, length, rest::binary>>,
         known_code,
         known_key,
         decoded
       )
       when byte_size(rest) >= length do
    <<value::binary-size(length), remaining::binary>> = rest

    if code == known_code do
      case decoded.known do
        nil ->
          decode_control_parameters(remaining, known_code, known_key, %{decoded | known: value})

        _existing ->
          {:error, :malformed_parameters}
      end
    else
      decoded = %{decoded | unknown: [{code, value} | decoded.unknown]}
      decode_control_parameters(remaining, known_code, known_key, decoded)
    end
  end

  defp decode_control_parameters(_parameters, _known_code, _known_key, _decoded),
    do: {:error, :malformed_parameters}

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
    if valid_tsap?(fields.src_tsap) and valid_tsap?(fields.dst_tsap) and
         valid_tpdu_size?(fields.tpdu_size) do
      {:ok, struct!(ConnectionRequest, fields)}
    else
      {:error, :malformed_parameters}
    end
  end

  defp connection_struct(@connection_confirm, fields) do
    if valid_optional_tsap?(fields.src_tsap) and valid_optional_tsap?(fields.dst_tsap) and
         valid_optional_tpdu_size?(fields.tpdu_size) do
      {:ok, struct!(ConnectionConfirm, fields)}
    else
      {:error, :malformed_parameters}
    end
  end

  defp validate_connection!(@connection_request, connection) do
    if valid_tsap?(connection.src_tsap) and valid_tsap?(connection.dst_tsap) and
         valid_tpdu_size?(connection.tpdu_size) do
      :ok
    else
      raise ArgumentError,
            "COTP Connection Request requires source/destination TSAP and TPDU size"
    end
  end

  defp validate_connection!(@connection_confirm, connection) do
    if valid_optional_tsap?(connection.src_tsap) and valid_optional_tsap?(connection.dst_tsap) and
         valid_optional_tpdu_size?(connection.tpdu_size) do
      :ok
    else
      raise ArgumentError, "invalid COTP Connection Confirm parameters"
    end
  end

  defp valid_tsap?(tsap), do: is_binary(tsap) and byte_size(tsap) in 1..16
  defp valid_optional_tsap?(nil), do: true
  defp valid_optional_tsap?(tsap), do: valid_tsap?(tsap)
  defp valid_optional_tpdu_size?(nil), do: true
  defp valid_optional_tpdu_size?(size), do: valid_tpdu_size?(size)

  defp validate_reference!(reference) when reference in 0..0xFFFF, do: :ok
  defp validate_reference!(_reference), do: raise(ArgumentError, "invalid COTP reference")

  defp validate_byte!(value) when value in 0..0xFF, do: :ok
  defp validate_byte!(_value), do: raise(ArgumentError, "invalid COTP class/option byte")

  defp split_binary(<<>>, _maximum_payload, []), do: [<<>>]
  defp split_binary(<<>>, _maximum_payload, chunks), do: Enum.reverse(chunks)

  defp split_binary(binary, maximum_payload, chunks)
       when byte_size(binary) <= maximum_payload,
       do: Enum.reverse([binary | chunks])

  defp split_binary(binary, maximum_payload, chunks) do
    <<chunk::binary-size(maximum_payload), remaining::binary>> = binary
    split_binary(remaining, maximum_payload, [chunk | chunks])
  end
end
