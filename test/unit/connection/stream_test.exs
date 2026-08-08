defmodule S7.Connection.StreamTest do
  use ExUnit.Case, async: true

  alias S7.Connection.Stream
  alias S7.Error
  alias S7.Protocol.PDU
  alias S7.Transport.{COTP, TPKT}
  alias S7.Transport.COTP.{ConnectionConfirm, Data}

  @opts [max_tpkt_size: 1024, receive_buffer_limit: 2048, pdu_size: 480]

  test "decodes fragmented TCP input and concatenated TPKT frames" do
    first = PDU.new(:ack_data, 11, <<0x05, 1>>, <<0xFF>>, error_class: 0, error_code: 0)
    second = PDU.new(:ack_data, 12, <<0x05, 1>>, <<0x05>>, error_class: 0, error_code: 0)
    binary = frame(first) <> frame(second)

    {stream, decoded} =
      binary
      |> :binary.bin_to_list()
      |> Enum.reduce({Stream.new(), []}, fn byte, {stream, decoded} ->
        assert {:ok, pdus, stream} = Stream.push(stream, <<byte>>, @opts)
        {stream, decoded ++ pdus}
      end)

    assert stream.buffer == <<>>
    assert decoded == [first, second]
  end

  test "reassembles numbered COTP data fragments" do
    pdu = PDU.new(:ack_data, 42, <<0x05, 1>>, <<0xFF>>, error_class: 0, error_code: 0)
    payload = pdu |> PDU.encode() |> IO.iodata_to_binary()
    split = div(byte_size(payload), 2)
    <<first::binary-size(split), second::binary>> = payload

    binary =
      frame_tpdu(%Data{payload: first, eot: false, tpdu_number: 0}) <>
        frame_tpdu(%Data{payload: second, eot: true, tpdu_number: 1})

    assert {:ok, [^pdu], %Stream{fragment_count: 0}} =
             Stream.push(Stream.new(), binary, @opts)
  end

  test "rejects invalid framing and bounded input violations" do
    assert {:error, %Error{layer: :tcp, reason: :receive_buffer_overflow}} =
             Stream.push(Stream.new(), <<0, 1, 2, 3, 4>>, receive_buffer_limit: 4)

    assert {:error, %Error{layer: :tpkt, reason: :invalid_tpkt}} =
             Stream.push(Stream.new(), <<2, 0, 0, 7, 2, 0xF0, 0x80>>, @opts)

    assert {:error, %Error{layer: :cotp, reason: :unexpected_tpdu}} =
             Stream.push(Stream.new(), frame_tpdu(%ConnectionConfirm{}), @opts)

    assert {:error, %Error{layer: :cotp, reason: :unexpected_tpdu_number}} =
             Stream.push(Stream.new(), frame_tpdu(%Data{payload: <<0>>, tpdu_number: 1}), @opts)

    oversized_opts = Keyword.put(@opts, :pdu_size, 8)

    assert {:error, %Error{layer: :s7, reason: :pdu_too_large}} =
             Stream.push(
               Stream.new(),
               frame_tpdu(%Data{payload: :binary.copy(<<0>>, 9)}),
               oversized_opts
             )
  end

  test "rejects malformed, invalid, and trailing S7 payloads" do
    pdu = PDU.new(:ack_data, 1, <<0x05, 1>>, <<0xFF>>)
    encoded = pdu |> PDU.encode() |> IO.iodata_to_binary()
    truncated_size = byte_size(encoded) - 1
    <<truncated::binary-size(truncated_size), _last>> = encoded

    assert {:error, %Error{reason: :malformed_response}} =
             Stream.push(Stream.new(), frame_tpdu(%Data{payload: truncated}), @opts)

    assert {:error, %Error{reason: :invalid_s7_pdu}} =
             Stream.push(Stream.new(), frame_tpdu(%Data{payload: <<0, 3, 0>>}), @opts)

    assert {:error, %Error{reason: :malformed_response}} =
             Stream.push(Stream.new(), frame_tpdu(%Data{payload: encoded <> <<0>>}), @opts)
  end

  test "fails when a fragmented PDU cannot finish within the fragment cap" do
    result =
      Enum.reduce_while(0..63, Stream.new(), fn number, stream ->
        binary = frame_tpdu(%Data{payload: <<>>, eot: false, tpdu_number: number})

        case Stream.push(stream, binary, @opts) do
          {:ok, [], stream} -> {:cont, stream}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    assert {:error, %Error{layer: :cotp, reason: :too_many_fragments}} = result
  end

  defp frame(pdu) do
    pdu
    |> PDU.encode()
    |> IO.iodata_to_binary()
    |> then(&frame_tpdu(%Data{payload: &1}))
  end

  defp frame_tpdu(tpdu) do
    payload = tpdu |> COTP.encode() |> IO.iodata_to_binary()
    %TPKT{payload: payload} |> TPKT.encode() |> IO.iodata_to_binary()
  end
end
