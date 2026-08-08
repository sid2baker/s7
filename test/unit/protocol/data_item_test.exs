defmodule S7.Protocol.DataItemTest do
  use ExUnit.Case, async: true

  alias S7.Protocol.DataItem

  test "encodes Write Var items with transport-specific length units" do
    assert DataItem.for_write(:bit, <<1>>) |> DataItem.encode() |> IO.iodata_to_binary() ==
             <<0, 0x03, 0, 1, 1>>

    assert DataItem.for_write(:word, <<0x12, 0x34>>)
           |> DataItem.encode()
           |> IO.iodata_to_binary() == <<0, 0x04, 0, 16, 0x12, 0x34>>

    assert DataItem.for_write(:int, <<0xFF, 0xFE>>)
           |> DataItem.encode()
           |> IO.iodata_to_binary() == <<0, 0x05, 0, 16, 0xFF, 0xFE>>

    assert DataItem.for_write(:real, <<0x41, 0x48, 0, 0>>)
           |> DataItem.encode()
           |> IO.iodata_to_binary() == <<0, 0x07, 0, 4, 0x41, 0x48, 0, 0>>

    assert DataItem.for_write(:word, <<0, 1, 0, 2>>)
           |> DataItem.encode()
           |> IO.iodata_to_binary() == <<0, 0x04, 0, 32, 0, 1, 0, 2>>
  end

  test "decodes one item and preserves following item bytes" do
    binary = <<0xFF, 0x04, 0, 16, 0x12, 0x34, 0xAA>>

    assert {:ok,
            %DataItem{
              return_code: 0xFF,
              transport_size: :byte,
              encoded_length: 16,
              data: <<0x12, 0x34>>
            }, <<0xAA>>} = DataItem.decode(binary)
  end

  test "decodes a failed item without a payload" do
    assert DataItem.decode(<<0x0A, 0, 0, 0>>) ==
             {:ok,
              %DataItem{return_code: 0x0A, transport_size: :none, encoded_length: 0, data: <<>>},
              <<>>}
  end

  test "reports truncated data and invalid transports" do
    assert DataItem.decode(<<>>) == {:more, 4}
    assert DataItem.decode(<<0xFF, 0x04, 0, 16, 1>>) == {:more, 1}
    assert DataItem.decode(<<0xFF, 0xFF, 0, 0>>) == {:error, :unsupported_transport_size}
    assert DataItem.decode(<<0x0A, 0, 0, 1>>) == {:error, :invalid_data_length}
    assert DataItem.decode(:not_binary) == {:error, :invalid_data_item}
  end

  test "encoder validates declared lengths and byte-sized fields" do
    item = %DataItem{return_code: 0, transport_size: :byte, encoded_length: 8, data: <<>>}
    assert_raise ArgumentError, fn -> DataItem.encode(item) end

    assert_raise ArgumentError, fn -> DataItem.encode(%{item | return_code: 256}) end
    assert_raise ArgumentError, fn -> DataItem.encode(%{item | encoded_length: 0x10000}) end
  end
end
