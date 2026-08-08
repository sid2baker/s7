defmodule S7.AddressTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Error}

  test "parses DB bit and scalar addresses" do
    assert {:ok,
            %Address{
              area: :db,
              db_number: 1,
              byte_offset: 20,
              bit_offset: 3,
              data_type: :bit,
              count: 1
            }} = Address.parse("DB1.DBX20.3")

    assert {:ok, %Address{data_type: :byte, byte_offset: 20}} = Address.parse("db1.dbb20")
    assert {:ok, %Address{data_type: :word, byte_offset: 20}} = Address.parse("DB1.DBW20")
    assert {:ok, %Address{data_type: :dword, byte_offset: 20}} = Address.parse("DB1.DBD20")
  end

  test "parses marker, input, and output addresses" do
    assert {:ok, %Address{area: :markers, data_type: :bit, bit_offset: 0}} =
             Address.parse("M10.0")

    assert {:ok, %Address{area: :markers, data_type: :byte}} = Address.parse("MB10")
    assert {:ok, %Address{area: :markers, data_type: :word}} = Address.parse("MW10")
    assert {:ok, %Address{area: :markers, data_type: :dword}} = Address.parse("MD10")
    assert {:ok, %Address{area: :inputs, data_type: :bit}} = Address.parse("I0.0")
    assert {:ok, %Address{area: :inputs, data_type: :byte}} = Address.parse("IB0")
    assert {:ok, %Address{area: :inputs, data_type: :word}} = Address.parse("IW0")
    assert {:ok, %Address{area: :outputs, data_type: :bit}} = Address.parse("Q0.0")
    assert {:ok, %Address{area: :outputs, data_type: :byte}} = Address.parse("QB0")
    assert {:ok, %Address{area: :outputs, data_type: :word}} = Address.parse("QW0")
  end

  test "validates explicitly constructed typed addresses" do
    address = %Address{
      area: :db,
      db_number: 7,
      byte_offset: 4,
      data_type: :real
    }

    assert {:ok, ^address} = Address.validate_scalar(address)
    assert Address.bit_address(address) == 32
  end

  test "rejects malformed and out-of-range addresses without raising" do
    for value <- [
          "",
          "DB1.DBX20",
          "DB1.DBW20.1",
          "M1.8",
          "DB0.DBW0",
          "XW1",
          <<0xFF>>,
          42
        ] do
      assert {:error, %Error{layer: :address}} = Address.parse(value)
    end

    address = %Address{area: :markers, byte_offset: 0x200000, data_type: :byte}
    assert {:error, %Error{reason: :invalid_offset}} = Address.validate(address)
  end

  test "v0.1 rejects multi-value address structs" do
    address = %Address{area: :markers, byte_offset: 0, data_type: :byte, count: 2}

    assert {:error, %Error{reason: :multiple_values_not_supported}} =
             Address.validate_scalar(address)
  end

  test "accepts fixed-count non-bit ranges and rejects unsupported bit ranges" do
    words = %Address{area: :db, db_number: 1, byte_offset: 10, data_type: :word, count: 4}
    assert Address.validate(words) == {:ok, words}

    bits = %Address{
      area: :db,
      db_number: 1,
      byte_offset: 10,
      bit_offset: 0,
      data_type: :bit,
      count: 2
    }

    assert {:error, %Error{reason: :multiple_bits_not_supported}} = Address.validate(bits)

    overflow = %Address{
      area: :markers,
      byte_offset: 0x1FFFFF,
      data_type: :word,
      count: 1
    }

    assert {:error, %Error{reason: :invalid_offset}} = Address.validate(overflow)
  end

  test "validates every structured address field" do
    invalid = [
      %Address{area: :timer, byte_offset: 0, data_type: :word},
      %Address{area: :markers, byte_offset: 0, data_type: :timer},
      %Address{area: :db, db_number: 0, byte_offset: 0, data_type: :byte},
      %Address{area: :markers, db_number: 1, byte_offset: 0, data_type: :byte},
      %Address{area: :markers, byte_offset: 0, data_type: :byte, count: 0}
    ]

    for address <- invalid do
      assert {:error, %Error{layer: :address}} = Address.validate(address)
    end

    assert {:error, %Error{reason: :invalid_address}} = Address.validate(:not_an_address)
  end
end
