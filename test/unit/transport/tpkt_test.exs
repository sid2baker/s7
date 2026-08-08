defmodule S7.Transport.TPKTTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias S7.Transport.TPKT

  property "decode(encode(packet)) preserves arbitrary payloads" do
    check all(payload <- binary(min_length: 3, max_length: 512)) do
      packet = %TPKT{payload: payload}
      encoded = packet |> TPKT.encode() |> IO.iodata_to_binary()

      assert {:ok, decoded, <<>>} = TPKT.decode(encoded)
      assert decoded == packet
    end
  end

  test "decodes multiple packets from one TCP segment" do
    first = %TPKT{payload: <<2, 0xF0, 0x80>>}
    second = %TPKT{payload: <<2, 0xF0, 0x80, 1, 2, 3>>}
    binary = IO.iodata_to_binary([TPKT.encode(first), TPKT.encode(second)])

    assert {:ok, ^first, remaining} = TPKT.decode(binary)
    assert {:ok, ^second, <<>>} = TPKT.decode(remaining)
  end

  test "reports exact requirements at every fragmentation boundary" do
    packet = %TPKT{payload: <<2, 0xF0, 0x80, 1, 2, 3, 4, 5>>}
    binary = packet |> TPKT.encode() |> IO.iodata_to_binary()

    for split <- 0..(byte_size(binary) - 1) do
      <<fragment::binary-size(split), rest::binary>> = binary
      assert {:more, needed} = TPKT.decode(fragment)
      assert needed > 0
      assert {:ok, ^packet, <<>>} = TPKT.decode(fragment <> rest)
    end
  end

  test "rejects invalid headers and configured oversized lengths" do
    assert {:error, :invalid_version} = TPKT.decode(<<2, 0, 0, 7, 2, 0xF0, 0x80>>)
    assert {:error, :invalid_reserved_byte} = TPKT.decode(<<3, 1, 0, 7, 2, 0xF0, 0x80>>)
    assert {:error, :invalid_length} = TPKT.decode(<<3, 0, 0, 6, 0, 0>>)
    assert {:error, :oversized_length} = TPKT.decode(<<3, 0, 0, 20>>, max_size: 10)
    assert {:error, :invalid_tpkt} = TPKT.decode(<<3, 0, 0, 7>>, max_size: 6)
    assert {:error, :invalid_tpkt} = TPKT.decode(<<3, 0, 0, 7>>, max_size: :infinity)
    assert {:error, :invalid_tpkt} = TPKT.decode(:not_binary)
    assert {:error, :invalid_tpkt} = TPKT.decode(<<>>, :not_options)
  end

  test "distinguishes a partial header from a partial payload" do
    assert TPKT.decode(<<3, 0>>) == {:more, 2}
    assert TPKT.decode(<<3, 0, 0, 10, 2, 0xF0, 0x80>>) == {:more, 3}
  end

  test "encoder rejects invalid structures and packet lengths" do
    assert_raise ArgumentError, fn -> TPKT.encode(%TPKT{payload: <<>>}) end
    assert_raise ArgumentError, fn -> TPKT.encode(:not_a_packet) end

    oversized = :binary.copy(<<0>>, 0xFFFF - 3)
    assert_raise ArgumentError, fn -> TPKT.encode(%TPKT{payload: oversized}) end
  end
end
