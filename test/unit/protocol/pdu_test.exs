defmodule S7.Protocol.PDUTest do
  use ExUnit.Case, async: true

  alias S7.Protocol.{Header, PDU}
  alias S7.Test.Fixture

  test "golden Setup request round-trips through the generic PDU" do
    fixture = Fixture.read!("setup/request.bin")

    assert {:ok,
            %PDU{
              header: %Header{
                rosctr: :job,
                pdu_reference: 0xFFFF,
                parameter_length: 8,
                data_length: 0
              },
              parameters: <<0xF0, 0, 0, 1, 0, 1, 7, 0x80>>,
              data: <<>>
            } = pdu, <<>>} = PDU.decode(fixture)

    assert IO.iodata_to_binary(PDU.encode(pdu)) == fixture
  end

  test "golden Ack-Data response round-trips" do
    fixture = Fixture.read!("setup/response.bin")

    assert {:ok, %PDU{header: %Header{rosctr: :ack_data, error_class: 0, error_code: 0}} = pdu,
            <<>>} = PDU.decode(fixture)

    assert IO.iodata_to_binary(PDU.encode(pdu)) == fixture
  end

  test "encoder derives lengths rather than trusting stale header values" do
    pdu = %PDU{
      header: %Header{
        rosctr: :job,
        pdu_reference: 1,
        parameter_length: 99,
        data_length: 99
      },
      parameters: <<1, 2>>,
      data: <<3>>
    }

    assert {:ok, %PDU{header: %Header{parameter_length: 2, data_length: 1}}, <<>>} =
             pdu |> PDU.encode() |> IO.iodata_to_binary() |> PDU.decode()
  end

  test "reports a truncated declared payload" do
    assert PDU.decode(<<0x32, 1, 0, 0, 0, 1, 0, 2, 0, 1, 0xAA>>) == {:more, 2}
  end
end
