defmodule S7.Protocol.WriteVarTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Data, Error}
  alias S7.Protocol.{PDU, WriteVar}
  alias S7.Test.Fixture

  test "encodes the capture-derived marker bit request exactly" do
    address = %Address{
      area: :markers,
      byte_offset: 1,
      bit_offset: 0,
      data_type: :bit
    }

    assert {:ok, value} = Data.encode(:bit, false)
    assert {:ok, request} = WriteVar.request(address, value, 1)

    assert IO.iodata_to_binary(PDU.encode(request)) == Fixture.read!("write/m1_0_request.bin")
  end

  test "decodes the capture-shaped successful response" do
    assert {:ok, response, <<>>} = PDU.decode(Fixture.read!("write/success_response.bin"))
    assert WriteVar.decode_response(response, 1) == :ok
  end

  test "maps item errors and rejects malformed responses" do
    denied = PDU.new(:ack_data, 1, <<5, 1>>, <<3>>)
    assert {:error, %Error{reason: :access_denied, code: 3}} = WriteVar.decode_response(denied, 1)

    malformed = PDU.new(:ack_data, 1, <<5, 2>>, <<0xFF>>)

    assert {:error, %Error{reason: :malformed_response}} =
             WriteVar.decode_response(malformed, 1)

    missing_code = PDU.new(:ack_data, 1, <<5, 1>>, <<>>)

    assert {:error, %Error{reason: :malformed_response}} =
             WriteVar.decode_response(missing_code, 1)
  end

  test "encodes aligned multi-item writes and decodes every return code" do
    byte = %Address{area: :markers, byte_offset: 0, data_type: :byte}
    word = %Address{area: :db, db_number: 1, byte_offset: 2, data_type: :word}

    assert {:ok, request} = WriteVar.request_many([{byte, <<0xAA>>}, {word, <<0x12, 0x34>>}], 7)
    assert <<0x05, 2, _items::binary-size(24)>> = request.parameters
    assert request.data == <<0, 0x04, 0, 8, 0xAA, 0, 0, 0x04, 0, 16, 0x12, 0x34>>

    response = PDU.new(:ack_data, 7, <<0x05, 2>>, <<0xFF, 0x05>>)

    assert {:ok, [:ok, {:error, %Error{reason: :address_out_of_range, code: 0x05}}]} =
             WriteVar.decode_responses(response, 2, 7)
  end

  test "rejects invalid multi-item writes and malformed response cardinality" do
    address = %Address{area: :markers, byte_offset: 0, data_type: :byte}
    assert {:error, %Error{reason: :invalid_item_count}} = WriteVar.request_many([], 1)

    assert {:error, %Error{reason: :invalid_item_count}} =
             WriteVar.request_many(List.duplicate({address, <<0>>}, 256), 1)

    assert {:error, %Error{reason: :invalid_item}} = WriteVar.request_many([:invalid], 1)

    response = PDU.new(:ack_data, 1, <<0x05, 2>>, <<0xFF>>)

    assert {:error, %Error{reason: :malformed_response}} =
             WriteVar.decode_responses(response, 2, 1)
  end
end
