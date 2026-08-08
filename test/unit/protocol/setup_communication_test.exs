defmodule S7.Protocol.SetupCommunicationTest do
  use ExUnit.Case, async: true

  alias S7.Error
  alias S7.Protocol.{PDU, SetupCommunication}
  alias S7.Test.Fixture

  test "encodes the capture-derived Setup request exactly" do
    setup = %SetupCommunication{max_amq_calling: 1, max_amq_called: 1, pdu_length: 1920}
    request = SetupCommunication.request(setup, 0xFFFF)

    assert IO.iodata_to_binary(PDU.encode(request)) == Fixture.read!("setup/request.bin")
  end

  test "decodes and validates the negotiated response" do
    assert {:ok, pdu, <<>>} = PDU.decode(Fixture.read!("setup/response.bin"))

    assert SetupCommunication.decode_response(pdu, 0xFFFF) ==
             {:ok,
              %SetupCommunication{
                max_amq_calling: 1,
                max_amq_called: 1,
                pdu_length: 240
              }}
  end

  test "rejects wrong references, header errors, and malformed parameters" do
    good = PDU.new(:ack_data, 3, <<0xF0, 0, 0, 1, 0, 1, 1, 0xE0>>)

    assert {:error, %Error{reason: :unexpected_pdu_reference}} =
             SetupCommunication.decode_response(good, 4)

    header_error =
      PDU.new(:ack_data, 3, <<0xF0, 0, 0, 1, 0, 1, 1, 0xE0>>, <<>>,
        error_class: 0x84,
        error_code: 1
      )

    assert {:error, %Error{reason: :protocol_error, code: {0x84, 1}}} =
             SetupCommunication.decode_response(header_error, 3)

    malformed = PDU.new(:ack_data, 3, <<0xF0, 0>>)

    assert {:error, %Error{reason: :malformed_response}} =
             SetupCommunication.decode_response(malformed, 3)
  end
end
