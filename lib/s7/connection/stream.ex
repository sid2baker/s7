defmodule S7.Connection.Stream do
  @moduledoc false

  alias S7.Error
  alias S7.Protocol.PDU
  alias S7.Transport.{COTP, TPKT}
  alias S7.Transport.COTP.{Data, DisconnectRequest, ErrorTPDU}

  @maximum_fragments 64

  defstruct buffer: <<>>,
            fragment_parts: [],
            fragment_count: 0,
            fragment_size: 0

  @type t :: %__MODULE__{
          buffer: binary(),
          fragment_parts: [binary()],
          fragment_count: non_neg_integer(),
          fragment_size: non_neg_integer()
        }

  @type option ::
          {:max_tpkt_size, pos_integer()}
          | {:pdu_size, pos_integer()}
          | {:tpdu_size, pos_integer()}
          | {:receive_buffer_limit, pos_integer()}

  @spec new(binary()) :: t()
  def new(buffer \\ <<>>) when is_binary(buffer), do: %__MODULE__{buffer: buffer}

  @spec push(t(), binary(), [option()]) :: {:ok, [PDU.t()], t()} | {:error, Error.t()}
  def push(%__MODULE__{} = stream, bytes, opts) when is_binary(bytes) and is_list(opts) do
    buffer = stream.buffer <> bytes
    limit = Keyword.fetch!(opts, :receive_buffer_limit)

    if byte_size(buffer) <= limit do
      decode_tpkts(%{stream | buffer: buffer}, opts, [])
    else
      {:error, error(:tcp, :receive_buffer_overflow, %{size: byte_size(buffer), limit: limit})}
    end
  end

  defp decode_tpkts(stream, opts, pdus) do
    case TPKT.decode(stream.buffer, max_size: Keyword.fetch!(opts, :max_tpkt_size)) do
      {:ok, packet, remaining} ->
        stream = %{stream | buffer: remaining}
        continue_tpkts(decode_tpdu(packet.payload, stream, opts), opts, pdus)

      {:more, _needed} ->
        {:ok, Enum.reverse(pdus), stream}

      {:error, reason} ->
        {:error, error(:tpkt, :invalid_tpkt, %{codec_reason: reason})}
    end
  end

  defp continue_tpkts({:ok, nil, stream}, opts, pdus),
    do: decode_tpkts(stream, opts, pdus)

  defp continue_tpkts({:ok, pdu, stream}, opts, pdus),
    do: decode_tpkts(stream, opts, [pdu | pdus])

  defp continue_tpkts({:error, %Error{} = error}, _opts, _pdus), do: {:error, error}

  defp decode_tpdu(payload, stream, opts) do
    tpdu_size = Keyword.fetch!(opts, :tpdu_size)

    if byte_size(payload) <= tpdu_size do
      decode_sized_tpdu(payload, stream, opts)
    else
      {:error,
       error(:cotp, :tpdu_too_large, %{
         size: byte_size(payload),
         negotiated_size: tpdu_size
       })}
    end
  end

  defp decode_sized_tpdu(payload, stream, opts) do
    case COTP.decode(payload) do
      {:ok, %Data{} = data} ->
        append_fragment(stream, data, opts)

      {:ok, %DisconnectRequest{} = request} ->
        {:error,
         error(:cotp, :remote_disconnect, %{
           reason: request.reason,
           additional_information: request.additional_information
         })}

      {:ok, %ErrorTPDU{} = tpdu} ->
        {:error,
         error(:cotp, :protocol_error, %{
           reject_cause: tpdu.reject_cause,
           invalid_tpdu: tpdu.invalid_tpdu
         })}

      {:ok, _tpdu} ->
        {:error, error(:cotp, :unexpected_tpdu)}

      {:more, needed} ->
        {:error, error(:cotp, :invalid_cotp, %{bytes_needed: needed})}

      {:error, reason} ->
        {:error, error(:cotp, :invalid_cotp, %{codec_reason: reason})}
    end
  end

  defp append_fragment(stream, _data, _opts)
       when stream.fragment_count >= @maximum_fragments do
    {:error, error(:cotp, :too_many_fragments)}
  end

  defp append_fragment(_stream, %Data{tpdu_number: number}, _opts) when number != 0 do
    {:error,
     error(:cotp, :unexpected_tpdu_number, %{
       expected: 0,
       received: number
     })}
  end

  defp append_fragment(stream, %Data{} = data, opts) do
    size = stream.fragment_size + byte_size(data.payload)
    pdu_size = Keyword.fetch!(opts, :pdu_size)

    if size <= pdu_size do
      finish_fragment(stream, data, size)
    else
      {:error, error(:s7, :pdu_too_large, %{size: size, negotiated_size: pdu_size})}
    end
  end

  defp finish_fragment(stream, %Data{eot: false, payload: payload}, size) do
    if stream.fragment_count + 1 >= @maximum_fragments do
      {:error, error(:cotp, :too_many_fragments)}
    else
      {:ok, nil,
       %{
         stream
         | fragment_parts: [payload | stream.fragment_parts],
           fragment_count: stream.fragment_count + 1,
           fragment_size: size
       }}
    end
  end

  defp finish_fragment(stream, %Data{eot: true, payload: payload}, _size) do
    binary =
      stream.fragment_parts
      |> Enum.reverse()
      |> then(&IO.iodata_to_binary([&1, payload]))

    with {:ok, pdu} <- decode_pdu(binary) do
      {:ok, pdu, reset_fragments(stream)}
    end
  end

  defp decode_pdu(binary) do
    case PDU.decode(binary) do
      {:ok, pdu, <<>>} -> {:ok, pdu}
      {:ok, _pdu, remaining} -> malformed(%{trailing_bytes: byte_size(remaining)})
      {:more, needed} -> malformed(%{bytes_needed: needed})
      {:error, reason} -> {:error, error(:s7, :invalid_s7_pdu, %{codec_reason: reason})}
    end
  end

  defp reset_fragments(stream) do
    %{
      stream
      | fragment_parts: [],
        fragment_count: 0,
        fragment_size: 0
    }
  end

  defp malformed(details), do: {:error, error(:s7, :malformed_response, details)}

  defp error(layer, reason, details \\ %{}),
    do: Error.new(layer, :request, reason, details: details)
end
