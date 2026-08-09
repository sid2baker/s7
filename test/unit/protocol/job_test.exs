defmodule S7.Protocol.JobTest do
  use ExUnit.Case, async: true

  alias S7.Error
  alias S7.Protocol.{Job, PDU}

  test "accepts a successful AckData header and rejects another ROSCTR" do
    assert Job.validate_response_header(PDU.new(:ack_data, 1, <<>>), :test) == :ok

    assert {:error, %Error{reason: :malformed_response, details: %{rosctr: :job}} = error} =
             Job.validate_response_header(PDU.new(:job, 1, <<>>), :test)

    refute Job.complete_rejection?(error)
  end

  test "maps known complete PLC rejection codes" do
    cases = [
      {0xD241, :access_denied},
      {0xD209, :object_not_found},
      {0xD20C, :invalid_block},
      {0xD2A1, :resource_busy},
      {0xD201, :operation_not_supported},
      {0x1234, :plc_error}
    ]

    for {code, reason} <- cases do
      assert {:error, %Error{code: ^code, reason: ^reason} = error} = Job.plc_error(:test, code)
      assert Job.complete_rejection?(error)
    end
  end
end
