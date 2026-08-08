defmodule S7.DataTest do
  use ExUnit.Case, async: true

  alias S7.{Data, Error}

  test "round-trips supported scalar types" do
    values = [
      bit: true,
      byte: 0xA5,
      word: 0xABCD,
      dword: 0xABCDEF01,
      int: -12_345,
      dint: -123_456_789,
      real: 12.5
    ]

    for {type, value} <- values do
      assert {:ok, encoded} = Data.encode(type, value)
      assert {:ok, decoded} = Data.decode(type, encoded)
      assert decoded == value
    end
  end

  test "uses network byte order and IEEE-754 binary32" do
    assert Data.encode(:word, 0x1234) == {:ok, <<0x12, 0x34>>}
    assert Data.encode(:dword, 0x12345678) == {:ok, <<0x12, 0x34, 0x56, 0x78>>}
    assert Data.encode(:int, -2) == {:ok, <<0xFF, 0xFE>>}
    assert Data.encode(:dint, -2) == {:ok, <<0xFF, 0xFF, 0xFF, 0xFE>>}
    assert Data.encode(:real, 12.5) == {:ok, <<0x41, 0x48, 0x00, 0x00>>}
  end

  test "accepts numeric bit values and decodes to booleans" do
    assert Data.encode(:bit, 0) == {:ok, <<0>>}
    assert Data.encode(:bit, 1) == {:ok, <<1>>}
    assert Data.decode(:bit, <<0>>) == {:ok, false}
    assert Data.decode(:bit, <<1>>) == {:ok, true}
  end

  test "supports signed and unsigned boundaries" do
    boundaries = [
      byte: [0, 0xFF],
      word: [0, 0xFFFF],
      dword: [0, 0xFFFFFFFF],
      int: [-0x8000, 0x7FFF],
      dint: [-0x80000000, 0x7FFFFFFF]
    ]

    for {type, values} <- boundaries, value <- values do
      assert {:ok, binary} = Data.encode(type, value)
      assert Data.decode(type, binary) == {:ok, value}
    end
  end

  test "rejects out-of-range values and wrong payload sizes" do
    for {type, value} <- [byte: -1, byte: 256, word: 65_536, int: 32_768, bit: 2] do
      assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(type, value)
    end

    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:word, <<1>>)
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:byte, <<1, 2>>)
    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(:real, 10 ** 400)
    assert {:error, %Error{reason: :data_type_not_supported}} = Data.encode(:timer, 1)
    assert {:error, %Error{reason: :data_type_not_supported}} = Data.decode(:timer, <<0, 1>>)
  end
end
