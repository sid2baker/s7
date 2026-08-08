defmodule S7.ProtocolTest do
  use ExUnit.Case, async: true

  alias S7.Error
  alias S7.Protocol
  alias S7.Protocol.PDU

  test "rejects unexpected response kinds and invalid response values" do
    job = PDU.new(:job, 1, <<>>)

    assert {:error, %Error{reason: :unexpected_rosctr}} =
             Protocol.validate_response(job, :read, 1)

    assert {:error, %Error{reason: :malformed_response}} =
             Protocol.validate_response(:not_a_pdu, :read, 1)
  end
end
