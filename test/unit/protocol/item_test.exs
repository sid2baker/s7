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

  test "preserves a fixed element count in S7ANY" do
    address = %Address{area: :db, db_number: 1, byte_offset: 20, data_type: :word, count: 3}

    assert {:ok, %Item{count: 3} = item} = Item.from_address(address)
    assert {:ok, ^item, <<>>} = item |> Item.encode() |> Item.decode()
  end

  test "maps every supported classic S7ANY transport and area" do
    transports = [
      bit: 0x01,
      byte: 0x02,
      char: 0x03,
      word: 0x04,
      int: 0x05,
      dword: 0x06,
      dint: 0x07,
      real: 0x08,
      date: 0x09,
      time_of_day: 0x0A,
      time: 0x0B,
      s5time: 0x0C,
      date_and_time: 0x0F,
      counter: 0x1C,
      timer: 0x1D
    ]

    areas = [
      counters: 0x1C,
      timers: 0x1D,
      peripheral: 0x80,
      inputs: 0x81,
      outputs: 0x82,
      markers: 0x83,
      db: 0x84,
      instance_db: 0x85,
      local: 0x86,
      previous_local: 0x87
    ]

    for {name, code} <- transports do
      assert Item.transport_code(name) == code

      item = %Item{
        transport_size: name,
        count: 1,
        db_number: 0,
        area: :markers,
        bit_address: 0
      }

      assert {:ok, ^item, <<>>} = item |> Item.encode() |> Item.decode()
    end

    for {name, code} <- areas do
      assert Item.area_code(name) == code

      item = %Item{
        transport_size: :byte,
        count: 1,
        db_number: 0,
        area: name,
        bit_address: 0
      }

      assert {:ok, ^item, <<>>} = item |> Item.encode() |> Item.decode()
    end
  end

  test "derives wire count and element addressing from semantic addresses" do
    string = %Address{area: :db, db_number: 1, byte_offset: 20, data_type: {:string, 10}}

    native_date = %Address{
      area: :db,
      db_number: 1,
      byte_offset: 4,
      data_type: :date,
      transport_size: :date
    }

    counter = %Address{area: :counters, element_offset: 42, data_type: :counter, count: 3}

    assert {:ok, %Item{transport_size: :byte, count: 12, bit_address: 160}} =
             Item.from_address(string)

    assert {:ok, %Item{transport_size: :date, count: 1, bit_address: 32}} =
             Item.from_address(native_date)

    assert {:ok,
            %Item{
              transport_size: :counter,
              count: 3,
              area: :counters,
              bit_address: 42
            }} = Item.from_address(counter)
  end

  test "rejects malformed and unsupported S7ANY items" do
    assert Item.decode(<<0x12>>) == {:more, 11}

    assert Item.decode(<<0x11, 0x0A, 0x10, 2, 0, 1, 0, 1, 0x84, 0, 0, 0>>) ==
             {:error, :invalid_specification_type}

    assert Item.decode(<<0x12, 0x0A, 0x11, 2, 0, 1, 0, 1, 0x84, 0, 0, 0>>) ==
             {:error, :invalid_syntax_id}

    assert Item.decode(<<0x12, 0x0A, 0x10, 0xFF, 0, 1, 0, 1, 0x84, 0, 0, 0>>) ==
             {:error, :unsupported_transport_size}

    assert Item.decode(<<0x12, 0x0A, 0x10, 2, 0, 1, 0, 1, 0xFF, 0, 0, 0>>) ==
             {:error, :unsupported_area}

    assert Item.decode(:not_binary) == {:error, :invalid_s7any_item}
  end

  test "encoder validates every bounded S7ANY field" do
    item = %Item{transport_size: :byte, count: 1, db_number: 1, area: :db, bit_address: 0}

    assert_raise ArgumentError, fn -> Item.encode(%{item | count: 0}) end
    assert_raise ArgumentError, fn -> Item.encode(%{item | db_number: -1}) end
    assert_raise ArgumentError, fn -> Item.encode(%{item | bit_address: 0x1000000}) end
  end
end
