defmodule S7.Protocol.CyclicTest do
  use ExUnit.Case, async: true

  alias S7.Cyclic, as: CyclicModel
  alias S7.Cyclic.Event.Item, as: EventItem
  alias S7.Error
  alias S7.Protocol.{Cyclic, PDU, UserData}
  alias S7.Test.Fixture

  test "encodes and decodes a typed fixed-cycle exchange" do
    assert {:ok, address} = S7.Address.parse("MW10")
    assert {:ok, interval} = Cyclic.interval(1_000)
    assert {:ok, specs} = Cyclic.typed_item_specs([address])
    assert {:ok, request} = Cyclic.subscribe_request(:cyclic, specs, interval)

    assert encoded(request, 0x20) == Fixture.read!("cyclic/fixed_subscribe_request.bin")

    response = decoded_pdu("cyclic/fixed_subscribe_response.bin")

    assert {:ok, 1,
            %CyclicModel.Event{
              job_id: 1,
              subfunction: 1,
              items: [
                %EventItem{
                  address: ^address,
                  value: 1234,
                  data: <<0x04, 0xD2>>,
                  error: nil
                }
              ]
            }} =
             Cyclic.decode_subscribe_response(
               response,
               request,
               0x20,
               :cyclic,
               [address],
               1
             )

    subscription = subscription(:cyclic, 1, specs, [address], interval, true)
    indication = decoded_userdata("cyclic/fixed_indication.bin")

    assert {:ok,
            %CyclicModel.Event{
              job_id: 1,
              items: [%EventItem{value: 1234, raw: <<0xFF, 0x04, 0, 16, 4, 210>>}]
            }} = Cyclic.decode_indication(indication, subscription)
  end

  test "matches captured change-driven setup, modify, indication, and teardown" do
    first_item = <<0x12, 0x07, 0xB0, 1, 5, 0, 0x51, 1, 0x72>>

    modified_item =
      <<0x12, 0x11, 0xB0, 3, 5, 0, 0x51, 1, 0x72, 0x1D, 0, 0x83, 0, 0x3C, 0x16, 0, 0x83, 1, 0x3E>>

    assert {:ok, interval} = Cyclic.interval(1_000)

    assert {:ok, request} =
             Cyclic.subscribe_request(:change_driven, [first_item], interval)

    assert encoded(request, 0x0F) == Fixture.read!("cyclic/change_subscribe_request.bin")

    response = decoded_pdu("cyclic/change_subscribe_response.bin")

    assert {:ok, 1,
            %CyclicModel.Event{
              items: [
                %EventItem{
                  transport_size: 0x09,
                  encoded_length: 6,
                  data: <<0xFF, 0x43, 0xF6, 0x90, 0x35, 0x60>>
                }
              ]
            }} =
             Cyclic.decode_subscribe_response(
               response,
               request,
               0x0F,
               :change_driven,
               nil,
               1
             )

    assert {:ok, modify} = Cyclic.modify_request(1, [modified_item], interval)
    assert encoded(modify, 0x24) == Fixture.read!("cyclic/change_modify_request.bin")

    assert {:ok, %CyclicModel.Event{items: [%EventItem{encoded_length: 59}]}} =
             Cyclic.decode_modify_response(
               decoded_pdu("cyclic/change_modify_response.bin"),
               modify,
               0x24,
               1,
               1
             )

    subscription = subscription(:change_driven, 3, [first_item], nil, interval, false)

    assert {:ok,
            %CyclicModel.Event{
              subfunction: 5,
              items: [%EventItem{encoded_length: 11, value: nil, error: nil}]
            }} =
             "cyclic/change_indication.bin"
             |> decoded_userdata()
             |> Cyclic.decode_indication(subscription)

    assert {:ok, unsubscribe} = Cyclic.unsubscribe_request(3)
    assert encoded(unsubscribe, 0x35) == Fixture.read!("cyclic/unsubscribe_request.bin")

    assert :ok =
             Cyclic.decode_unsubscribe_response(
               decoded_pdu("cyclic/unsubscribe_response.bin"),
               unsubscribe,
               0x35,
               3
             )
  end

  test "selects only exact representable intervals and prefers coarser bases" do
    assert Cyclic.interval(100) ==
             {:ok,
              %CyclicModel.Interval{
                base: :hundred_milliseconds,
                factor: 1,
                milliseconds: 100
              }}

    assert {:ok, %CyclicModel.Interval{base: :second, factor: 2}} = Cyclic.interval(2_000)
    assert {:ok, %CyclicModel.Interval{base: :ten_seconds, factor: 6}} = Cyclic.interval(60_000)

    for invalid <- [0, 99, 1_050, 255_100, 2_550_001, :invalid] do
      assert {:error, %Error{reason: :invalid_cyclic_interval}} = Cyclic.interval(invalid)
    end

    assert {:error, %Error{reason: :invalid_cyclic_interval}} =
             Cyclic.interval(%CyclicModel.Interval{
               base: :second,
               factor: 2,
               milliseconds: 1_000
             })
  end

  test "rejects unsupported modes, malformed specs, and malformed events" do
    assert {:ok, interval} = Cyclic.interval(1_000)

    assert {:error, %Error{reason: :unsupported_cyclic_mode}} =
             Cyclic.subscribe_request(:unknown, [<<0x12, 0x0A, 0x10, 0::72>>], interval)

    for item <- [<<>>, <<0x11, 0>>, <<0x12, 0x0A, 0x11, 0::72>>, <<0x12, 7, 0xB0, 0>>] do
      assert {:error, %Error{reason: :invalid_cyclic_item}} = Cyclic.raw_item_specs([item])
    end

    assert {:ok, address} = S7.Address.parse("MW10")
    assert {:ok, specs} = Cyclic.typed_item_specs([address])
    subscription = subscription(:cyclic, 1, specs, [address], interval, true)
    indication = decoded_userdata("cyclic/fixed_indication.bin")

    assert {:error, %Error{reason: :unexpected_subscription_job}} =
             Cyclic.decode_indication(indication, %{subscription | job_id: 2})

    malformed = put_in(indication.payload.data, <<0, 2, indication.payload.data::binary>>)

    assert {:error, %Error{reason: :malformed_response}} =
             Cyclic.decode_indication(malformed, subscription)

    rejected = put_in(indication.payload.data, <<0, 1, 5, 4, 0, 16, 4, 210>>)

    assert {:ok,
            %CyclicModel.Event{
              items: [%EventItem{value: nil, error: %Error{reason: :address_out_of_range}}]
            }} = Cyclic.decode_indication(rejected, subscription)

    for malformed_parameter <- [
          %{indication.parameter | data_unit_reference: nil},
          %{indication.parameter | last_data_unit: 1}
        ] do
      assert {:error, %Error{reason: :malformed_response}} =
               Cyclic.decode_indication(
                 %{indication | parameter: malformed_parameter},
                 subscription
               )
    end

    assert {:error, %Error{reason: :userdata_error, code: 0xD241}} =
             Cyclic.decode_indication(
               put_in(indication.parameter.error_code, 0xD241),
               subscription
             )

    short_parameter = %{
      indication.parameter
      | data_unit_reference: nil,
        last_data_unit: nil,
        error_code: nil
    }

    assert {:ok, %CyclicModel.Event{}} =
             Cyclic.decode_indication(
               %{indication | parameter: short_parameter},
               subscription
             )

    assert {:error, %Error{reason: :malformed_response}} =
             Cyclic.decode_indication(indication, %{subscription | addresses: []})

    assert {:error, %Error{reason: :malformed_response}} =
             Cyclic.decode_indication(indication, %{subscription | mode: :unknown})
  end

  test "requires consistent final-unit metadata on successful responses" do
    assert {:ok, address} = S7.Address.parse("MW10")
    assert {:ok, interval} = Cyclic.interval(1_000)
    assert {:ok, specs} = Cyclic.typed_item_specs([address])
    assert {:ok, request} = Cyclic.subscribe_request(:cyclic, specs, interval)
    response_pdu = decoded_pdu("cyclic/fixed_subscribe_response.bin")
    assert {:ok, response} = UserData.from_pdu(response_pdu)

    short_parameter = %{
      response.parameter
      | data_unit_reference: nil,
        last_data_unit: nil,
        error_code: nil
    }

    assert {:ok, short_pdu} = UserData.to_pdu(%{response | parameter: short_parameter}, 0x20)

    assert {:ok, 1, %CyclicModel.Event{}} =
             Cyclic.decode_subscribe_response(
               short_pdu,
               request,
               0x20,
               :cyclic,
               [address],
               1
             )

    malformed_parameters = [%{response.parameter | last_data_unit: 1}]

    for parameter <- malformed_parameters do
      assert {:ok, malformed_pdu} = UserData.to_pdu(%{response | parameter: parameter}, 0x20)

      assert {:error, %Error{reason: :malformed_response}} =
               Cyclic.decode_subscribe_response(
                 malformed_pdu,
                 request,
                 0x20,
                 :cyclic,
                 [address],
                 1
               )
    end
  end

  test "validates constructor boundaries and decodes every request action" do
    assert {:error, %Error{reason: :invalid_items}} = Cyclic.typed_item_specs([])

    assert {:error, %Error{reason: :invalid_cyclic_item, details: %{index: 0}}} =
             Cyclic.typed_item_specs([:not_an_address])

    assert {:error, %Error{reason: :invalid_items}} = Cyclic.raw_item_specs([])
    assert {:ok, interval} = Cyclic.interval(60_000)
    assert {:ok, address} = S7.Address.parse("MW10")
    assert {:ok, [item_spec]} = Cyclic.typed_item_specs([address])

    assert {:error, %Error{reason: :invalid_cyclic_request}} =
             Cyclic.subscribe_request(:cyclic, [item_spec], nil)

    assert {:error, %Error{reason: :invalid_cyclic_request}} =
             Cyclic.modify_request(0, [item_spec], interval)

    assert {:error, %Error{reason: :invalid_cyclic_request}} = Cyclic.unsubscribe_request(0)
    assert Cyclic.mode_subfunctions(:unknown) == []

    assert {:ok, request} = Cyclic.subscribe_request(:cyclic, [item_spec], interval)

    assert {:ok,
            %{
              action: :subscribe,
              mode: :cyclic,
              interval: %CyclicModel.Interval{base: :ten_seconds, factor: 6},
              item_specs: [^item_spec]
            }} = Cyclic.decode_request(request, :test_decode_request)

    assert {:ok, %{action: :subscribe, mode: :change_driven, job_id: 0}} =
             "cyclic/change_subscribe_request.bin"
             |> decoded_userdata()
             |> Cyclic.decode_request(:test_decode_request)

    assert {:ok, %{action: :modify, mode: :change_driven, job_id: 1}} =
             "cyclic/change_modify_request.bin"
             |> decoded_userdata()
             |> Cyclic.decode_request(:test_decode_request)

    assert {:ok, %{action: :unsubscribe, job_id: 3}} =
             "cyclic/unsubscribe_request.bin"
             |> decoded_userdata()
             |> Cyclic.decode_request(:test_decode_request)

    trailing = put_in(request.payload.data, request.payload.data <> <<0>>)

    assert {:error, %Error{reason: :malformed_response, details: %{trailing_bytes: 1}}} =
             Cyclic.decode_request(trailing, :test_decode_request)

    truncated_size = byte_size(request.payload.data) - 1
    <<truncated::binary-size(^truncated_size), _last>> = request.payload.data

    assert {:error, %Error{reason: :malformed_response, details: %{bytes_needed: 1}}} =
             Cyclic.decode_request(
               put_in(request.payload.data, truncated),
               :test_decode_request
             )
  end

  test "validates response job identity, payload shape, and PLC errors" do
    assert {:ok, address} = S7.Address.parse("MW10")
    assert {:ok, interval} = Cyclic.interval(1_000)
    assert {:ok, specs} = Cyclic.typed_item_specs([address])
    assert {:ok, request} = Cyclic.subscribe_request(:cyclic, specs, interval)
    response = decoded_userdata("cyclic/fixed_subscribe_response.bin")

    empty = put_in(response.payload.data, <<>>)

    assert {:ok, 1, nil} =
             empty
             |> to_pdu(0x20)
             |> Cyclic.decode_subscribe_response(request, 0x20, :cyclic, [address], 1)

    wrong_job = put_in(response.parameter.sequence, 0)

    assert {:error, %Error{reason: :malformed_response}} =
             wrong_job
             |> to_pdu(0x20)
             |> Cyclic.decode_subscribe_response(request, 0x20, :cyclic, [address], 1)

    wrong_method = put_in(response.parameter.method, 0x11)

    assert {:error, %Error{reason: :malformed_response}} =
             wrong_method
             |> to_pdu(0x20)
             |> Cyclic.decode_subscribe_response(request, 0x20, :cyclic, [address], 1)

    wrong_transport = put_in(response.payload.transport_size, 0x04)

    assert {:error, %Error{reason: :malformed_response}} =
             wrong_transport
             |> to_pdu(0x20)
             |> Cyclic.decode_subscribe_response(request, 0x20, :cyclic, [address], 1)

    for {code, reason} <- [{0xD209, :object_not_found}, {0xD804, :invalid_cyclic_interval}] do
      rejected = put_in(response.parameter.error_code, code)

      assert {:error, %Error{reason: ^reason, code: ^code}} =
               rejected
               |> to_pdu(0x20)
               |> Cyclic.decode_subscribe_response(request, 0x20, :cyclic, [address], 1)
    end

    assert {:ok, modify} = Cyclic.modify_request(1, specs, interval)
    modify_response = decoded_userdata("cyclic/change_modify_response.bin")
    wrong_modify_job = put_in(modify_response.parameter.sequence, 2)

    assert {:error, %Error{reason: :malformed_response}} =
             wrong_modify_job
             |> to_pdu(0x24)
             |> Cyclic.decode_modify_response(modify, 0x24, 1, 1)

    assert {:ok, unsubscribe} = Cyclic.unsubscribe_request(3)
    unsubscribe_response = decoded_userdata("cyclic/unsubscribe_response.bin")
    wrong_unsubscribe_job = put_in(unsubscribe_response.parameter.sequence, 2)

    assert {:error, %Error{reason: :malformed_response}} =
             wrong_unsubscribe_job
             |> to_pdu(0x35)
             |> Cyclic.decode_unsubscribe_response(unsubscribe, 0x35, 3)

    octet_success = %{
      unsubscribe_response
      | payload: %{unsubscribe_response.payload | return_code: 0xFF, transport_size: 0x09}
    }

    assert :ok =
             octet_success
             |> to_pdu(0x35)
             |> Cyclic.decode_unsubscribe_response(unsubscribe, 0x35, 3)
  end

  test "preserves raw fixed records and rejects malformed indication envelopes" do
    assert {:ok, interval} = Cyclic.interval(1_000)
    assert {:ok, address} = S7.Address.parse("MW10")
    assert {:ok, specs} = Cyclic.typed_item_specs([address])
    indication = decoded_userdata("cyclic/fixed_indication.bin")
    raw_subscription = subscription(:cyclic, 1, specs, nil, interval, false)

    assert {:ok, %CyclicModel.Event{items: [%EventItem{address: nil, value: nil}]}} =
             Cyclic.decode_indication(indication, raw_subscription)

    assert {:error, %Error{reason: :malformed_response}} =
             Cyclic.decode_indication(%{indication | parameter: nil}, raw_subscription)

    assert {:error, %Error{reason: :address_out_of_range}} =
             Cyclic.decode_indication(
               put_in(indication.payload.return_code, 0x05),
               raw_subscription
             )

    <<count::binary-size(2), return_code, _transport, rest::binary>> = indication.payload.data
    malformed_data = count <> <<return_code, 0x03>> <> rest

    assert {:ok, %CyclicModel.Event{items: [%EventItem{transport_size: :bit, value: nil}]}} =
             Cyclic.decode_indication(
               put_in(indication.payload.data, malformed_data),
               raw_subscription
             )

    truncated_size = byte_size(indication.payload.data) - 1
    <<truncated::binary-size(^truncated_size), _last>> = indication.payload.data

    assert {:error, %Error{reason: :malformed_response}} =
             Cyclic.decode_indication(
               put_in(indication.payload.data, truncated),
               raw_subscription
             )
  end

  defp subscription(mode, job_id, specs, addresses, interval, typed?) do
    %CyclicModel.Subscription{
      connection: self(),
      reference: make_ref(),
      job_id: job_id,
      mode: mode,
      interval: interval,
      item_specs: specs,
      typed?: typed?,
      addresses: addresses
    }
  end

  defp encoded(message, reference) do
    assert {:ok, pdu} = UserData.to_pdu(message, reference)
    pdu |> PDU.encode() |> IO.iodata_to_binary()
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
