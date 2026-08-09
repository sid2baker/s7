defmodule S7.Protocol.PIServiceTest do
  use ExUnit.Case, async: true

  alias S7.{Block, Error}
  alias S7.Protocol.{PDU, PIService}
  alias S7.Test.Fixture

  test "encodes and decodes captured block insertion" do
    block = %Block{type: :db, number: 1}
    assert {:ok, request} = PIService.block_request(block, :insert, :download_block)
    request = put_in(request.header.pdu_reference, 0x8400)

    assert encode(request) == Fixture.read!("download/insert_db1_request.bin")

    assert PIService.decode_block_request(request, :test) ==
             {:ok, %{action: :insert, block: block}}

    assert Fixture.read!("download/pi_response.bin")
           |> fixture_pdu()
           |> PIService.decode_response(:test) == :ok
  end

  test "encodes and decodes block deletion" do
    block = %Block{type: :db, number: 1}
    assert {:ok, request} = PIService.block_request(block, :delete, :delete_block)
    request = put_in(request.header.pdu_reference, 0x8400)

    assert encode(request) == Fixture.read!("download/delete_db1_request.bin")

    assert PIService.decode_block_request(request, :test) ==
             {:ok, %{action: :delete, block: block}}
  end

  test "maps complete PLC rejections and rejects malformed envelopes" do
    rejected = PDU.new(:ack, 1, <<>>, <<>>, error_class: 0xD2, error_code: 0x41)

    assert {:error, %Error{reason: :access_denied, code: 0xD241} = error} =
             PIService.decode_response(rejected, :delete_block)

    assert PIService.complete_rejection?(error)

    for malformed <- [
          PDU.new(:job, 1, <<0x28>>),
          PDU.new(:ack_data, 1, <<0x29>>),
          PDU.new(:ack_data, 1, <<0x28>>, <<0>>)
        ] do
      assert {:error, %Error{reason: :malformed_response}} =
               PIService.decode_response(malformed, :test)
    end

    assert {:error, %Error{reason: :invalid_block_request}} =
             PIService.block_request(%Block{type: :db, number: 1}, :unknown, :test)
  end

  test "rejects malformed block action and identity fields" do
    {:ok, request} = PIService.block_request(%Block{type: :db, number: 1}, :insert, :test)

    malformed_action =
      update_in(request.parameters, fn parameters ->
        <<prefix::binary-size(21), _command::binary-size(5)>> = parameters
        prefix <> "_NOPE"
      end)

    assert {:error, %Error{reason: :malformed_response}} =
             PIService.decode_block_request(malformed_action, :test)

    malformed_type =
      update_in(request.parameters, fn parameters ->
        <<prefix::binary-size(13), _type, suffix::binary>> = parameters
        prefix <> <<0xFF>> <> suffix
      end)

    assert {:error, %Error{reason: :malformed_response}} =
             PIService.decode_block_request(malformed_type, :test)
  end

  defp fixture_pdu(binary) do
    assert {:ok, pdu, <<>>} = PDU.decode(binary)
    pdu
  end

  defp encode(pdu), do: pdu |> PDU.encode() |> IO.iodata_to_binary()
end
