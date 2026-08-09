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

  test "supports IEC integer aliases and 64-bit numbers" do
    values = [
      sint: -0x80,
      usint: 0xFF,
      uint: 0xFFFF,
      udint: 0xFFFFFFFF,
      lword: 0xFFFFFFFFFFFFFFFF,
      lint: -0x8000000000000000,
      ulint: 0xFFFFFFFFFFFFFFFF,
      lreal: 12.5
    ]

    for {type, value} <- values do
      assert {:ok, encoded} = Data.encode(type, value)
      assert Data.decode(type, encoded) == {:ok, value}
    end

    assert Data.encode(:lint, -2) == {:ok, <<0xFFFFFFFFFFFFFFFE::unsigned-big-64>>}
    assert Data.encode(:lreal, 12.5) == {:ok, <<12.5::float-big-64>>}
  end

  test "encodes byte and wide characters" do
    assert Data.encode(:char, "A") == {:ok, <<0x41>>}
    assert Data.decode(:char, <<0xE4>>) == {:ok, <<0xE4>>}
    assert Data.encode(:wchar, "ß") == {:ok, <<0x00, 0xDF>>}
    assert Data.decode(:wchar, <<0x00, 0xDF>>) == {:ok, "ß"}

    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(:char, "AB")
    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(:wchar, "😀")
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:wchar, <<0xD8, 0x00>>)
  end

  test "encodes fixed Siemens STRING and WSTRING storage" do
    assert Data.encode({:string, 5}, "abc") == {:ok, <<5, 3, "abc", 0, 0>>}
    assert Data.decode({:string, 5}, <<5, 3, "abc", 0, 0>>) == {:ok, "abc"}

    assert Data.encode({:wstring, 2}, "Aß") ==
             {:ok, <<0, 2, 0, 2, 0, 0x41, 0, 0xDF>>}

    assert Data.decode({:wstring, 2}, <<0, 2, 0, 2, 0, 0x41, 0, 0xDF>>) ==
             {:ok, "Aß"}

    assert Data.encode({:wstring, 2}, "😀") ==
             {:ok, <<0, 2, 0, 2, 0xD8, 0x3D, 0xDE, 0x00>>}

    assert Data.size({:string, 5}) == {:ok, 7}
    assert Data.size({:wstring, 5}) == {:ok, 14}
  end

  test "validates malformed and overflowing strings" do
    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode({:string, 2}, "abc")

    assert {:error, %Error{reason: :value_out_of_range}} =
             Data.encode({:wstring, 1}, "😀")

    assert {:error, %Error{reason: :malformed_value}} =
             Data.decode({:string, 5}, <<4, 1, "a", 0, 0, 0, 0>>)

    assert {:error, %Error{reason: :malformed_value}} =
             Data.decode({:string, 5}, <<5, 6, "abcdef">>)

    assert {:error, %Error{reason: :malformed_value}} =
             Data.decode({:wstring, 1}, <<0, 1, 0, 1, 0xD8, 0x00>>)

    assert {:error, %Error{reason: :data_type_not_supported}} = Data.size({:string, 255})
    assert {:error, %Error{reason: :data_type_not_supported}} = Data.size({:wstring, 16_383})
  end

  test "uses Siemens DATE, TIME, and TIME_OF_DAY representations" do
    assert Data.encode(:date, ~D[1990-01-01]) == {:ok, <<0, 0>>}
    assert Data.encode(:date, ~D[1990-01-02]) == {:ok, <<0, 1>>}
    assert Data.decode(:date, <<0, 1>>) == {:ok, ~D[1990-01-02]}
    assert Data.encode(:time, -1) == {:ok, <<0xFFFFFFFF::unsigned-big-32>>}
    assert Data.decode(:time, <<0xFFFFFFFF::unsigned-big-32>>) == {:ok, -1}

    time = ~T[01:02:03.004]
    assert Data.encode(:time_of_day, time) == {:ok, <<3_723_004::unsigned-big-32>>}
    assert Data.decode(:time_of_day, <<3_723_004::unsigned-big-32>>) == {:ok, time}
  end

  test "uses the classic BCD DATE_AND_TIME representation" do
    value = ~N[2024-08-09 12:34:56.123]
    encoded = <<0x24, 0x08, 0x09, 0x12, 0x34, 0x56, 0x12, 0x36>>

    assert Data.encode(:date_and_time, value) == {:ok, encoded}
    assert Data.decode(:date_and_time, encoded) == {:ok, value}

    assert Data.encode(:date_and_time, ~N[1990-01-01 00:00:00.000]) ==
             {:ok, <<0x90, 0x01, 0x01, 0, 0, 0, 0, 0x02>>}
  end

  test "uses validated BCD for S5TIME, timers, and counters" do
    assert Data.encode(:s5time, 2_000) == {:ok, <<0x02, 0x00>>}
    assert Data.decode(:s5time, <<0x02, 0x00>>) == {:ok, 2_000}
    assert Data.encode(:timer, 10_000) == {:ok, <<0x11, 0x00>>}
    assert Data.decode(:timer, <<0x39, 0x99>>) == {:ok, 9_990_000}
    assert Data.encode(:counter, 123) == {:ok, <<0x01, 0x23>>}
    assert Data.decode(:counter, <<0x09, 0x99>>) == {:ok, 999}

    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(:s5time, 1)
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:s5time, <<0, 0x0A>>)
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:counter, <<0x0A, 0>>)
  end

  test "rejects invalid temporal values" do
    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(:date, ~D[1989-12-31])
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:date, <<0xFF, 0xFF>>)

    assert {:error, %Error{reason: :value_out_of_range}} =
             Data.encode(:time_of_day, ~T[00:00:00.000001])

    assert {:error, %Error{reason: :malformed_value}} =
             Data.decode(:time_of_day, <<86_400_000::unsigned-big-32>>)

    assert {:error, %Error{reason: :value_out_of_range}} =
             Data.encode(:date_and_time, ~N[2090-01-01 00:00:00.000])

    assert {:error, %Error{reason: :malformed_value}} =
             Data.decode(:date_and_time, <<0x24, 8, 9, 0x12, 0x34, 0x56, 0x12, 0x31>>)
  end

  test "round-trips fixed-count values in wire order" do
    values = [
      byte: [0, 1, 0xFF],
      word: [0x1234, 0xABCD],
      dword: [0x12345678, 0xABCDEF01],
      int: [-0x8000, 0, 0x7FFF],
      dint: [-0x80000000, 0x7FFFFFFF],
      real: [1.5, -12.25]
    ]

    for {type, elements} <- values do
      assert {:ok, encoded} = Data.encode(type, elements, length(elements))
      assert byte_size(encoded) == Data.size(type) |> elem(1) |> Kernel.*(length(elements))
      assert Data.decode(type, encoded, length(elements)) == {:ok, elements}
    end
  end

  test "validates array counts, elements, and raw payload sizes" do
    assert {:error, %Error{reason: :value_count_mismatch}} = Data.encode(:word, [1], 2)

    assert {:error, %Error{reason: :value_out_of_range, details: %{index: 1}}} =
             Data.encode(:byte, [1, 256], 2)

    assert {:error, %Error{reason: :raw_size_mismatch}} = Data.decode(:word, <<0, 1>>, 2)
    assert {:error, %Error{reason: :multiple_bits_not_supported}} = Data.encode(:bit, [true], 2)
    assert {:error, %Error{reason: :multiple_bits_not_supported}} = Data.decode(:bit, <<1, 0>>, 2)

    assert Data.encoded_size(:real, 3) == {:ok, 12}
    assert {:error, %Error{reason: :invalid_count}} = Data.encoded_size(:word, 0)
    assert {:error, %Error{reason: :invalid_count}} = Data.encoded_size(:word, 0x10000)
    assert {:error, %Error{reason: :multiple_bits_not_supported}} = Data.encoded_size(:bit, 2)
    assert {:error, %Error{reason: :invalid_count}} = Data.encode(:word, [], 0x10000)
    assert {:error, %Error{reason: :invalid_count}} = Data.decode(:word, <<>>, 0)
    assert Data.validate_raw(:byte, <<1, 2, 3>>, 3) == {:ok, <<1, 2, 3>>}
    assert {:error, %Error{reason: :raw_size_mismatch}} = Data.validate_raw(:word, <<1>>, 1)
    assert {:error, %Error{reason: :raw_size_mismatch}} = Data.validate_raw(:word, :bad, 1)
  end

  test "rejects out-of-range values and wrong payload sizes" do
    for {type, value} <- [byte: -1, byte: 256, word: 65_536, int: 32_768, bit: 2] do
      assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(type, value)
    end

    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:word, <<1>>)
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:byte, <<1, 2>>)
    assert {:error, %Error{reason: :value_out_of_range}} = Data.encode(:real, 10 ** 400)
    assert {:error, %Error{reason: :data_type_not_supported}} = Data.encode(:unknown, 1)
    assert {:error, %Error{reason: :data_type_not_supported}} = Data.decode(:unknown, <<0, 1>>)
    assert {:error, %Error{reason: :malformed_value}} = Data.decode(:word, :not_binary)
    assert {:error, %Error{reason: :data_type_not_supported}} = Data.size(:unknown)
  end
end
