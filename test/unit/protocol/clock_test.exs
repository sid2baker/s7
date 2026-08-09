defmodule S7.Protocol.ClockTest do
  use ExUnit.Case, async: true

  alias S7.{Error, PLCClock}
  alias S7.Protocol.{Clock, PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}
  alias S7.Test.Fixture

  test "round-trips the captured read-clock exchange" do
    assert {:ok, request} = Clock.read_request()
    assert encoded(request, 0x1600) == Fixture.read!("clock/read_request.bin")

    response = Fixture.read!("clock/read_response.bin")
    assert {:ok, pdu, <<>>} = PDU.decode(response)

    assert {:ok,
            %PLCClock{
              datetime: ~N[2016-02-08 14:51:37.916],
              reserved: 0,
              century_hint: 0x19,
              raw: <<0, 0x19, 0x16, 0x02, 0x08, 0x14, 0x51, 0x37, 0x91, 0x62>>
            }} = Clock.decode_response(pdu, request, 0x1600, :read)

    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == response
  end

  test "round-trips the captured set-clock exchange" do
    datetime = ~N[2016-02-08 23:08:10.000]
    assert {:ok, request} = Clock.set_request(datetime)
    assert encoded(request, 0x1700) == Fixture.read!("clock/set_request.bin")

    assert {:ok, pdu, <<>>} = Fixture.read!("clock/set_response.bin") |> PDU.decode()
    assert Clock.decode_response(pdu, request, 0x1700, :set) == {:ok, :ok}
  end

  test "validates BCD, calendar, weekday, precision, and year pivot" do
    assert {:ok, %PLCClock{datetime: ~N[2089-12-31 23:59:59.999]}} =
             Clock.decode_timestamp(<<0, 0x19, 0x89, 0x12, 0x31, 0x23, 0x59, 0x59, 0x99, 0x97>>)

    assert {:ok, %PLCClock{datetime: ~N[1990-01-01 00:00:00.000]}} =
             Clock.decode_timestamp(<<0, 0x19, 0x90, 1, 1, 0, 0, 0, 0, 0x02>>)

    assert {:ok, %PLCClock{datetime: ~N[2000-02-29 00:00:00.000]}} =
             Clock.decode_timestamp(<<0, 0x19, 0x00, 0x02, 0x29, 0, 0, 0, 0, 0x03>>)

    for invalid <- [
          <<0, 0x19, 0x1A, 1, 1, 0, 0, 0, 0, 0x02>>,
          <<0, 0x19, 0x24, 2, 30, 0, 0, 0, 0, 0x01>>,
          <<0, 0x19, 0x24, 1, 1, 0, 0, 0, 0, 0x01>>,
          <<0>>
        ] do
      assert {:error, %Error{reason: :malformed_response}} = Clock.decode_timestamp(invalid)
    end

    assert {:error, %Error{reason: :invalid_clock_value}} =
             Clock.set_request(~N[2089-12-31 23:59:59.000001])

    assert {:error, %Error{reason: :invalid_clock_value}} = Clock.set_request(:invalid)
  end

  test "rejects malformed response envelopes and continuations" do
    assert {:ok, request} = Clock.read_request()

    response = %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :response,
        function_group: :time,
        subfunction: 1,
        sequence: 0,
        data_unit_reference: 1,
        last_data_unit: 1,
        error_code: 0
      },
      payload: %Payload{transport_size: 9, data: <<0::80>>}
    }

    assert {:ok, pdu} = UserData.to_pdu(response, 1)

    assert {:error, %Error{reason: :malformed_response}} =
             Clock.decode_response(pdu, request, 1, :read)

    bad_payload = %{response | parameter: %{response.parameter | last_data_unit: 0}}
    bad_payload = %{bad_payload | payload: %{response.payload | transport_size: 4}}
    assert {:ok, pdu} = UserData.to_pdu(bad_payload, 1)

    assert {:error, %Error{reason: :malformed_response}} =
             Clock.decode_response(pdu, request, 1, :read)
  end

  defp encoded(message, reference) do
    assert {:ok, pdu} = UserData.to_pdu(message, reference)
    pdu |> PDU.encode() |> IO.iodata_to_binary()
  end
end
