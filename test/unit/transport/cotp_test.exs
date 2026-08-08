defmodule S7.Transport.COTPTest do
  use ExUnit.Case, async: true

  alias S7.Test.Fixture
  alias S7.Transport.COTP
  alias S7.Transport.COTP.{ConnectionConfirm, ConnectionRequest, Data}

  test "connection request golden fixture decodes and encodes exactly" do
    fixture = Fixture.read!("cotp/connection_request.bin")

    expected = %ConnectionRequest{
      src_tsap: <<0x01, 0x00>>,
      dst_tsap: <<0x01, 0x02>>,
      tpdu_size: 1024,
      destination_reference: 0,
      source_reference: 1
    }

    assert COTP.decode(fixture) == {:ok, expected}
    assert IO.iodata_to_binary(COTP.encode(expected)) == fixture
  end

  test "connection confirm golden fixture decodes and encodes exactly" do
    fixture = Fixture.read!("cotp/connection_confirm.bin")

    expected = %ConnectionConfirm{
      src_tsap: <<0x01, 0x02>>,
      dst_tsap: <<0x01, 0x00>>,
      tpdu_size: 1024,
      destination_reference: 1,
      source_reference: 1
    }

    assert COTP.decode(fixture) == {:ok, expected}
    assert IO.iodata_to_binary(COTP.encode(expected)) == fixture
  end

  test "data golden fixture preserves payload and EOT" do
    fixture = Fixture.read!("cotp/data.bin")
    <<2, 0xF0, 0x80, payload::binary>> = fixture
    expected = %Data{payload: payload}

    assert COTP.decode(fixture) == {:ok, expected}
    assert IO.iodata_to_binary(COTP.encode(expected)) == fixture
  end

  test "connection parameters may arrive in another order" do
    fixture =
      Base.decode16!("11D00001000100C0010AC2020100C1020102")

    assert {:ok, %ConnectionConfirm{tpdu_size: 1024, src_tsap: <<1, 2>>, dst_tsap: <<1, 0>>}} =
             COTP.decode(fixture)
  end

  test "reports truncation and rejects malformed TPDUs" do
    assert COTP.decode(<<>>) == {:more, 2}
    assert COTP.decode(<<2, 0xF0>>) == {:more, 1}
    assert COTP.decode(<<3, 0xF0, 0x80, 0>>) == {:error, :invalid_header_length}
    assert COTP.decode(<<1, 0x70>>) == {:error, :unsupported_tpdu}
    assert COTP.decode(<<8, 0xD0, 0, 1, 0, 1, 0, 0xC0>>) == {:more, 1}

    assert COTP.decode(<<7, 0xD0, 0, 1, 0, 1, 0, 0xC0>>) ==
             {:error, :malformed_parameters}

    assert COTP.decode(<<6, 0xE0, 0, 0, 0, 1, 0>>) == {:error, :malformed_parameters}
  end
end
