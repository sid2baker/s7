defmodule S7.Protocol.AlarmTest do
  use ExUnit.Case, async: true

  alias S7.Alarm, as: AlarmModel
  alias S7.Alarm.Acknowledgement.Result, as: AcknowledgementResult
  alias S7.Alarm.Event.Object, as: AlarmObject
  alias S7.Alarm.Event.Object.AssociatedValue
  alias S7.Alarm.Query.Record, as: QueryRecord
  alias S7.Error
  alias S7.Protocol.{Alarm, PDU, UserData}
  alias S7.Test.Fixture

  test "matches captured S7-300 subscription, query, and teardown packets" do
    assert {:ok, subscribe} = Alarm.subscription_request(:alarm_s, "HmiRtm  ", 0x01)
    assert encoded(subscribe, 1) == Fixture.read!("alarm/s300_subscribe_request.bin")

    assert :ok =
             Alarm.decode_subscription_response(
               decoded_pdu("alarm/s300_subscribe_response.bin"),
               subscribe,
               1,
               :alarm_s,
               :subscribe,
               :subscribe_alarms
             )

    selector = {:alarm_type, :alarm_s}
    assert {:ok, query} = Alarm.query_request(selector)
    assert encoded(query, 1) == Fixture.read!("alarm/s300_query_request.bin")

    assert {:ok,
            %AlarmModel.Query{
              selector: ^selector,
              return_code: 0x0A,
              complete_length: 0,
              records: []
            }} =
             Alarm.decode_query_response(
               decoded_pdu("alarm/s300_query_empty_response.bin"),
               query,
               1,
               selector
             )

    assert {:ok, unsubscribe} = Alarm.unsubscribe_request(:alarm_s)
    assert encoded(unsubscribe, 1) == Fixture.read!("alarm/s300_unsubscribe_request.bin")

    assert :ok =
             Alarm.decode_subscription_response(
               decoded_pdu("alarm/s300_unsubscribe_response.bin"),
               unsubscribe,
               1,
               :alarm_s,
               :unsubscribe,
               :unsubscribe_alarms
             )
  end

  test "matches captured S7-400 subscription and decodes all query records" do
    assert {:ok, subscribe} = Alarm.subscription_request(:alarm_8, "S7CHN_02", 0x01)
    assert encoded(subscribe, 9) == Fixture.read!("alarm/s400_subscribe_request.bin")

    assert :ok =
             Alarm.decode_subscription_response(
               decoded_pdu("alarm/s400_subscribe_response.bin"),
               subscribe,
               9,
               :alarm_8,
               :subscribe,
               :subscribe_alarms
             )

    selector = {:alarm_type, :alarm_8}
    assert {:ok, query} = Alarm.query_request(selector)

    assert {:ok,
            %AlarmModel.Query{
              reported_count: 1,
              return_code: 0xFF,
              transport_size: 0x09,
              complete_length: 48,
              records: [
                %QueryRecord{alarm_type: :alarm_8, event_id: 0x2F},
                %QueryRecord{alarm_type: :alarm_8, event_id: 0xAF},
                %QueryRecord{alarm_type: :alarm_8, event_id: 0xBB},
                %QueryRecord{
                  alarm_type: :alarm_8,
                  event_id: 0xC2,
                  event_state: 0x30,
                  ack_state_going: 0xFF,
                  ack_state_coming: 0xCF
                }
              ]
            }} =
             Alarm.decode_query_response(
               decoded_pdu("alarm/s400_query_response.bin"),
               query,
               0x0A,
               selector
             )
  end

  test "decodes captured ALARM_8 objects and preserves associated values" do
    indication = decoded_userdata("alarm/alarm8_indication.bin")

    assert {:ok,
            %AlarmModel.Event{
              kind: :alarm_8,
              subfunction: 0x05,
              timestamp: %AlarmModel.Timestamp{
                datetime: ~N[1994-01-06 00:27:20.397],
                weekday: 5
              },
              function_id: 0x40,
              objects: [
                %AlarmObject{
                  syntax_id: 0x16,
                  associated_value_count: 8,
                  event_id: 0xAF,
                  event_state: 0,
                  local_state: 0,
                  ack_state_going: 0xFE,
                  ack_state_coming: 0xFE,
                  associated_values: [
                    %AssociatedValue{
                      transport_size: 0x04,
                      encoded_length: 16,
                      data: <<0, 1>>,
                      error: nil
                    }
                    | remaining_values
                  ]
                } = object
              ]
            } = event} = Alarm.decode_indication(indication)

    assert [_, _, _, _, _, _, _] = remaining_values
    assert Enum.all?(remaining_values, &(&1.data == <<0xFF, 0xFF>>))

    assert object.raw ==
             object.specification_raw <>
               IO.iodata_to_binary(Enum.map(object.associated_values, & &1.raw))

    assert event.raw == indication.payload.data
  end

  test "decodes captured NOTIFY records with bounded bit-length values" do
    assert {:ok,
            %AlarmModel.Event{
              kind: :notify,
              objects: [
                %AlarmObject{
                  event_id: 1,
                  event_state: 1,
                  associated_values: [first, second, third]
                }
              ]
            }} =
             "alarm/notify_indication.bin"
             |> decoded_userdata()
             |> Alarm.decode_indication()

    assert byte_size(first.data) == 32
    assert byte_size(second.data) == 4
    assert byte_size(third.data) == 4
    assert Enum.map([first, second, third], & &1.encoded_length) == [256, 32, 32]
  end

  test "matches modeled acknowledgment packets and decodes acknowledgment indications" do
    acknowledgement = %AlarmModel.Acknowledgement{
      event_id: 0xAF,
      ack_state_going: 0xFE,
      ack_state_coming: 0xFE
    }

    assert {:ok, request} = Alarm.acknowledgement_request([acknowledgement])
    assert encoded(request, 0x42) == Fixture.read!("alarm/acknowledgement_request.bin")

    assert {:ok,
            [
              %AcknowledgementResult{
                acknowledgement: ^acknowledgement,
                return_code: 0xFF,
                status: :ok,
                error: nil
              }
            ]} =
             Alarm.decode_acknowledgement_response(
               decoded_pdu("alarm/acknowledgement_response.bin"),
               request,
               0x42,
               [acknowledgement]
             )

    assert {:ok,
            %AlarmModel.Event{
              kind: :acknowledgement,
              function_id: 9,
              objects: [
                %AlarmObject{
                  syntax_id: 0x19,
                  event_id: 0xAF,
                  event_state: nil,
                  ack_state_going: 0xFE,
                  ack_state_coming: 0xFE,
                  associated_values: []
                }
              ]
            }} =
             "alarm/acknowledgement_indication.bin"
             |> decoded_userdata()
             |> Alarm.decode_indication()
  end

  test "normalizes received objects and preserves per-object acknowledgment errors" do
    assert {:ok, event} =
             "alarm/alarm8_indication.bin"
             |> decoded_userdata()
             |> Alarm.decode_indication()

    assert {:ok, [acknowledgement]} = Alarm.acknowledgements(event)
    assert acknowledgement.event_id == 0xAF
    assert {:ok, request} = Alarm.acknowledgement_request([acknowledgement])
    response = decoded_userdata("alarm/acknowledgement_response.bin")
    rejected = put_in(response.payload.data, <<9, 1, 3>>)

    assert {:ok, [%AcknowledgementResult{status: :error, error: %Error{reason: :access_denied}}]} =
             Alarm.decode_acknowledgement_response(
               to_pdu(rejected, 0x42),
               request,
               0x42,
               [acknowledgement]
             )
  end

  test "decodes every request selector and rejects malformed constructor input" do
    for {selector, expected} <- [
          {{:alarm_type, :alarm_s}, {:alarm_type, :alarm_s}},
          {{:alarm_type, :alarm_8}, {:alarm_type, :alarm_8}},
          {{:event_id, 0xAABBCCDD}, {:event_id, 0xAABBCCDD}}
        ] do
      assert {:ok, request} = Alarm.query_request(selector)
      assert {:ok, %{action: :query, selector: ^expected}} = Alarm.decode_request(request, :test)
    end

    assert {:ok, subscribe} = Alarm.subscription_request(:alarm_s, "12345678")

    assert {:ok,
            %{
              action: :subscribe,
              alarm_type: :alarm_s,
              subscription_key: "12345678",
              event_mask: 0
            }} = Alarm.decode_request(subscribe, :test)

    assert {:ok, unsubscribe} = Alarm.unsubscribe_request(:alarm_8, "12345678")

    assert {:ok, %{action: :unsubscribe, alarm_type: :alarm_8}} =
             Alarm.decode_request(unsubscribe, :test)

    for invalid <- [
          fn -> Alarm.subscription_request(:unknown) end,
          fn -> Alarm.subscription_request(:alarm_s, "short") end,
          fn -> Alarm.subscription_request(:alarm_s, "12345678", 0x80) end,
          fn -> Alarm.query_request({:alarm_type, :scan}) end,
          fn -> Alarm.query_request({:event_id, -1}) end,
          fn -> Alarm.acknowledgements([]) end,
          fn ->
            Alarm.acknowledgements(%AlarmModel.Acknowledgement{
              event_id: -1,
              ack_state_going: 0,
              ack_state_coming: 0
            })
          end
        ] do
      assert {:error, %Error{}} = invalid.()
    end
  end

  test "rejects malformed lengths, timestamps, states, references, and response bodies" do
    assert {:ok, subscribe} = Alarm.subscription_request(:alarm_s)
    response = decoded_userdata("alarm/s300_subscribe_response.bin")

    assert {:error, %Error{reason: :malformed_response}} =
             response
             |> put_in([Access.key!(:payload), Access.key!(:data)], <<2, 0, 5, 1, 0>>)
             |> to_pdu(1)
             |> Alarm.decode_subscription_response(
               subscribe,
               1,
               :alarm_s,
               :subscribe,
               :subscribe_alarms
             )

    assert {:error, %Error{reason: :alarm_subscription_rejected, code: 1}} =
             response
             |> put_in([Access.key!(:payload), Access.key!(:data)], <<1, 0, 9, 1, 0>>)
             |> to_pdu(1)
             |> Alarm.decode_subscription_response(
               subscribe,
               1,
               :alarm_s,
               :subscribe,
               :subscribe_alarms
             )

    assert {:ok, query} = Alarm.query_request({:alarm_type, :alarm_s})
    query_response = decoded_userdata("alarm/s300_query_empty_response.bin")

    assert {:error, %Error{reason: :unexpected_pdu_reference}} =
             Alarm.decode_query_response(
               to_pdu(query_response, 2),
               query,
               1,
               {:alarm_type, :alarm_s}
             )

    malformed_query = put_in(query_response.payload.data, <<0, 1, 0xFF, 9, 0, 12, 10, 0>>)

    assert {:error, %Error{reason: :malformed_response}} =
             Alarm.decode_query_response(malformed_query, {:alarm_type, :alarm_s}, :query_alarms)

    indication = decoded_userdata("alarm/alarm8_indication.bin")

    invalid_timestamp =
      put_in(
        indication.payload.data,
        <<0::64,
          binary_part(indication.payload.data, 8, byte_size(indication.payload.data) - 8)::binary>>
      )

    assert {:error, %Error{reason: :malformed_response}} =
             Alarm.decode_indication(invalid_timestamp)

    truncated = binary_part(indication.payload.data, 0, byte_size(indication.payload.data) - 1)

    assert {:error, %Error{reason: :malformed_response}} =
             Alarm.decode_indication(put_in(indication.payload.data, truncated))

    wrong_service = put_in(indication.parameter.subfunction, 0x07)

    assert {:error, %Error{reason: :unsupported_alarm_indication, code: 0x07}} =
             Alarm.decode_indication(wrong_service)
  end

  defp encoded(message, reference) do
    message |> to_pdu(reference) |> PDU.encode() |> IO.iodata_to_binary()
  end

  defp to_pdu(message, reference) do
    assert {:ok, pdu} = UserData.to_pdu(message, reference)
    pdu
  end

  defp decoded_pdu(path) do
    fixture = Fixture.read!(path)
    assert {:ok, pdu, <<>>} = PDU.decode(fixture)
    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == fixture
    pdu
  end

  defp decoded_userdata(path) do
    assert {:ok, message} = path |> decoded_pdu() |> UserData.from_pdu()
    message
  end
end
