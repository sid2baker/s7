defmodule S7.Protocol.ReadVarTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Error}
  alias S7.Protocol.{PDU, ReadVar}
  alias S7.Test.Fixture

  test "encodes a one-item DB word request" do
    address = %Address{area: :db, db_number: 1, byte_offset: 20, data_type: :word}
    assert {:ok, request} = ReadVar.request(address, 42)

    assert IO.iodata_to_binary(PDU.encode(request)) ==
             <<0x32, 1, 0, 0, 0, 42, 0, 14, 0, 0, 0x04, 1, 0x12, 0x0A, 0x10, 0x04, 0, 1, 0, 1,
               0x84, 0, 0, 160>>
  end

  test "maps the capture-derived PLC item error" do
    address = %Address{area: :db, db_number: 1, byte_offset: 0, data_type: :byte}
    assert {:ok, response, <<>>} = PDU.decode(Fixture.read!("read/object_not_found_response.bin"))

    assert {:error, %Error{reason: :object_not_found, code: 0x0A}} =
             ReadVar.decode_response(response, address, 0)
  end

  test "decodes typed successful responses and raw bytes" do
    cases = [
      {:bit, :bit, 1, <<1>>, true},
      {:byte, :byte, 8, <<0xA5>>, 0xA5},
      {:word, :byte, 16, <<0x04, 0xD2>>, 1234},
      {:dword, :byte, 32, <<0x12, 0x34, 0x56, 0x78>>, 0x12345678},
      {:int, :integer, 16, <<0xFF, 0xFE>>, -2},
      {:dint, :integer, 32, <<0xFF, 0xFF, 0xFF, 0xFE>>, -2},
      {:real, :real, 4, <<0x41, 0x48, 0, 0>>, 12.5}
    ]

    for {data_type, transport, length, payload, expected} <- cases do
      address = %Address{area: :markers, byte_offset: 0, data_type: data_type}
      response = response(7, transport, length, payload)

      assert ReadVar.decode_raw_response(response, address, 7) == {:ok, payload}
      assert ReadVar.decode_response(response, address, 7) == {:ok, expected}
    end
  end

  test "rejects wrong references, truncated payloads, and transport mismatches" do
    address = %Address{area: :markers, byte_offset: 0, data_type: :word}
    response = response(7, :byte, 16, <<0, 1>>)

    assert {:error, %Error{reason: :unexpected_pdu_reference}} =
             ReadVar.decode_response(response, address, 8)

    truncated = PDU.new(:ack_data, 7, <<4, 1>>, <<0xFF, 0x04, 0, 16, 1>>)

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(truncated, address, 7)

    mismatch = response(7, :integer, 16, <<0, 1>>)

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(mismatch, address, 7)

    invalid_parameters = %{response | parameters: <<0x04, 2>>}

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(invalid_parameters, address, 7)

    trailing_data = %{response | data: response.data <> <<0>>}

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(trailing_data, address, 7)

    invalid_item = %{response | data: <<0xFF, 0xFF, 0, 0>>}

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(invalid_item, address, 7)
  end

  defp response(reference, transport, encoded_length, payload) do
    transport_code = %{bit: 0x03, byte: 0x04, integer: 0x05, real: 0x07}[transport]
    data = <<0xFF, transport_code, encoded_length::unsigned-big-16, payload::binary>>
    PDU.new(:ack_data, reference, <<0x04, 1>>, data)
  end
end
