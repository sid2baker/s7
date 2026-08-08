defmodule S7.Protocol.HeaderTest do
  use ExUnit.Case, async: true

  alias S7.Protocol.Header

  test "encodes and decodes Job headers" do
    header = %Header{
      rosctr: :job,
      pdu_reference: 42,
      parameter_length: 8,
      data_length: 0
    }

    encoded = Header.encode(header)

    assert encoded == <<0x32, 0x01, 0, 0, 0, 42, 0, 8, 0, 0>>
    assert Header.decode(encoded <> <<1, 2>>) == {:ok, header, <<1, 2>>}
  end

  test "Ack-Data headers include error class and code" do
    header = %Header{
      rosctr: :ack_data,
      pdu_reference: 0xFFFF,
      parameter_length: 2,
      data_length: 4,
      error_class: 0x84,
      error_code: 1
    }

    assert Header.decode(Header.encode(header)) == {:ok, header, <<>>}
  end

  test "reports partial headers and rejects invalid identifiers" do
    assert Header.decode(<<>>) == {:more, 2}
    assert Header.decode(<<0x32, 1, 0>>) == {:more, 7}
    assert Header.decode(<<0x32, 3, 0>>) == {:more, 9}
    assert Header.decode(<<0x31, 1>>) == {:error, :invalid_protocol_id}
    assert Header.decode(<<0x32, 0xFF>>) == {:error, :unsupported_rosctr}

    assert Header.decode(<<0x32, 1, 0, 1, 0, 1, 0, 0, 0, 0>>) ==
             {:error, :invalid_reserved_field}

    assert Header.decode(<<0x32, 3, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0>>) ==
             {:error, :invalid_reserved_field}

    assert Header.decode(:not_binary) == {:error, :invalid_s7_pdu}
  end

  test "encoder rejects fields outside their wire ranges" do
    base = %Header{rosctr: :job, pdu_reference: 1, parameter_length: 0, data_length: 0}

    assert_raise ArgumentError, fn -> Header.encode(%{base | pdu_reference: -1}) end
    assert_raise ArgumentError, fn -> Header.encode(%{base | parameter_length: 0x10000}) end

    ack = %{base | rosctr: :ack, error_class: 256}
    assert_raise ArgumentError, fn -> Header.encode(ack) end
  end
end
