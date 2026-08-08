defmodule S7.Protocol.ItemTest do
  use ExUnit.Case, async: true

  alias S7.Address
  alias S7.Protocol.{Item, PDU}
  alias S7.Test.Fixture

  test "decodes the capture-derived DB1 64-byte S7ANY item" do
    assert {:ok, %PDU{parameters: <<0x04, 1, item_binary::binary>>}, <<>>} =
             Fixture.read!("read/db1_64_bytes_request.bin") |> PDU.decode()

    expected = %Item{
      transport_size: :byte,
      count: 64,
      db_number: 1,
      area: :db,
      bit_address: 0
    }

    assert Item.decode(item_binary) == {:ok, expected, <<>>}
    assert Item.encode(expected) == item_binary
  end

  test "encodes byte offsets as a 24-bit bit address" do
    address = %Address{area: :db, db_number: 1, byte_offset: 20, data_type: :word}

    assert {:ok, item} = Item.from_address(address)

    assert Item.encode(item) ==
             <<0x12, 0x0A, 0x10, 0x04, 0, 1, 0, 1, 0x84, 0, 0, 160>>
  end

  test "maps every v0.1 transport and area" do
    assert Item.transport_code(:bit) == 0x01
    assert Item.transport_code(:byte) == 0x02
    assert Item.transport_code(:word) == 0x04
    assert Item.transport_code(:int) == 0x05
    assert Item.transport_code(:dword) == 0x06
    assert Item.transport_code(:dint) == 0x07
    assert Item.transport_code(:real) == 0x08
    assert Item.area_code(:inputs) == 0x81
    assert Item.area_code(:outputs) == 0x82
    assert Item.area_code(:markers) == 0x83
    assert Item.area_code(:db) == 0x84
  end

  test "rejects malformed and unsupported S7ANY items" do
    assert Item.decode(<<0x12>>) == {:more, 11}

    assert Item.decode(<<0x11, 0x0A, 0x10, 2, 0, 1, 0, 1, 0x84, 0, 0, 0>>) ==
             {:error, :invalid_specification_type}

    assert Item.decode(<<0x12, 0x0A, 0x11, 2, 0, 1, 0, 1, 0x84, 0, 0, 0>>) ==
             {:error, :invalid_syntax_id}

    assert Item.decode(<<0x12, 0x0A, 0x10, 0xFF, 0, 1, 0, 1, 0x84, 0, 0, 0>>) ==
             {:error, :unsupported_transport_size}
  end
end
