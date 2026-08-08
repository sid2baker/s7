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
  end
end
