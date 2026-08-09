defmodule S7.Protocol.ProgrammerTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Error, ProgrammerEvent, VariableStatus}
  alias S7.Protocol.{PDU, Programmer, UserData}
  alias S7.Protocol.Programmer.Job
  alias S7.Test.Fixture
  alias S7.VariableStatus.Item

  test "round-trips the captured variable-status job" do
    addresses = variable_addresses()
    assert {:ok, request, job} = Programmer.variable_status_request(addresses)

    assert encoded(request, 0x6E03) ==
             Fixture.read!("programmer/variable_status_setup_request.bin")

    setup_response = decoded_pdu("programmer/variable_status_setup_response.bin")

    assert {:ok, %Job{service: :variable_status, subfunction: 2, sequence: 2} = job} =
             Programmer.decode_start_response(
               setup_response,
               request,
               job,
               0x6E03,
               :variable_status
             )

    assert {:ok, enable} = Programmer.enable_request(job, :variable_status)
    assert encoded(enable, 0x6F03) == Fixture.read!("programmer/enable_request.bin")

    enable_response = decoded_pdu("programmer/enable_response.bin")

    assert Programmer.decode_management_response(
             enable_response,
             enable,
             0x6F03,
             :variable_status
           ) == :ok

    indication = decoded_userdata("programmer/variable_status_indication.bin")

    assert {:ok,
            %ProgrammerEvent{
              service: :variable_status,
              subfunction: 2,
              sequence: 2,
              parameters: <<1, 0, 0, 2>>,
              data: data,
              raw: raw
            } = event} = Programmer.decode_indication(indication, job, :variable_status)

    assert data ==
             <<2::16, 0xFF, 9, 6::16, 0x41, 0x33, 0x85, 0x1F, 0xDE, 0xAD, 0xFF, 9, 1::16, 2, 0>>

    assert raw == <<4::16, 18::16, 1, 0, 0, 2, data::binary>>

    assert {:ok,
            %VariableStatus{
              sequence: 2,
              parameters: <<1, 0, 0, 2>>,
              items: [
                %Item{
                  return_code: 0xFF,
                  transport_size: 9,
                  encoded_length: 6,
                  data: <<0x41, 0x33, 0x85, 0x1F, 0xDE, 0xAD>>,
                  padding: <<>>,
                  value: [0x41, 0x33, 0x85, 0x1F, 0xDE, 0xAD],
                  error: nil
                },
                %Item{
                  return_code: 0xFF,
                  transport_size: 9,
                  encoded_length: 1,
                  data: <<2>>,
                  padding: <<0>>,
                  value: 2,
                  error: nil
                }
              ]
            }} = Programmer.decode_variable_status(event, addresses)

    assert {:ok, delete} = Programmer.delete_request(job, :variable_status)
    assert encoded(delete, 0xDE03) == Fixture.read!("programmer/delete_request.bin")

    delete_response = decoded_pdu("programmer/delete_response.bin")

    assert Programmer.decode_management_response(
             delete_response,
             delete,
             0xDE03,
             :variable_status
           ) == :ok
  end

  test "preserves a captured block-status v2 indication as raw records" do
    setup_pdu = decoded_pdu("programmer/block_status_v2_setup_request.bin")
    assert {:ok, captured_setup} = UserData.from_pdu(setup_pdu)

    assert {:ok, parameters, data} =
             Programmer.decode_service_data(captured_setup.payload.data, :programmer_diagnostic)

    assert byte_size(parameters) == 28
    assert byte_size(data) == 28

    assert {:ok, request, job} =
             Programmer.start_request(:block_status_v2, parameters, data)

    assert encoded(request, 0x6906) ==
             Fixture.read!("programmer/block_status_v2_setup_request.bin")

    response = decoded_pdu("programmer/block_status_v2_setup_response.bin")

    assert {:ok, %Job{sequence: 3} = job} =
             Programmer.decode_start_response(
               response,
               request,
               job,
               0x6906,
               :programmer_diagnostic
             )

    indication = decoded_userdata("programmer/block_status_v2_indication.bin")

    assert {:ok,
            %ProgrammerEvent{
              service: :block_status_v2,
              sequence: 3,
              parameters: <<1, 0, 0, 1>>,
              data: indication_data,
              raw: raw
            }} = Programmer.decode_indication(indication, job, :programmer_diagnostic)

    assert byte_size(indication_data) == 46
    assert raw == <<4::16, 46::16, 1, 0, 0, 1, indication_data::binary>>
  end

  test "encodes every evidence-backed variable-status address family" do
    addresses = [
      address(:markers, :bit, byte_offset: 1, bit_offset: 2),
      address(:inputs, :byte, byte_offset: 3),
      address(:outputs, :word, byte_offset: 4),
      address(:peripheral, :dword, byte_offset: 5),
      address(:db, :real, byte_offset: 6, db_number: 7),
      address(:counters, :counter, element_offset: 8),
      address(:timers, :timer, element_offset: 9)
    ]

    assert {:ok, request, _job} = Programmer.variable_status_request(addresses)

    assert {:ok, _parameters, <<7::16, encoded_addresses::binary>>} =
             Programmer.decode_service_data(request.payload.data, :variable_status)

    assert encoded_addresses ==
             <<0x00, 2, 0::16, 1::16, 0x11, 1, 0::16, 3::16, 0x22, 1, 0::16, 4::16, 0x33, 1,
               0::16, 5::16, 0x73, 1, 7::16, 6::16, 0x64, 1, 0::16, 8::16, 0x54, 1, 0::16, 9::16>>
  end

  test "rejects destructive and unsupported programmer subfunctions" do
    for subfunction <- [0x06, 0x08, 0x09, 0x0A, 0x0C, 0x12, 0x16, :flash_led, :invalid] do
      assert {:error,
              %Error{
                reason: :unsupported_programmer_subfunction,
                details: %{subfunction: ^subfunction}
              }} = Programmer.start_request(subfunction, <<>>, <<>>)
    end
  end

  test "rejects unsupported addresses before creating a job" do
    invalid_addresses = [
      address(:local, :byte, byte_offset: 0),
      address(:instance_db, :word, byte_offset: 0, db_number: 1),
      address(:peripheral, :bit, byte_offset: 0, bit_offset: 0),
      address(:markers, :lreal, byte_offset: 0),
      address(:markers, :byte, byte_offset: 0, count: 256),
      address(:markers, :byte, byte_offset: 0x10000)
    ]

    for address <- invalid_addresses do
      assert {:error, %Error{layer: :address}} =
               Programmer.variable_status_request([address])
    end

    assert {:error, %Error{reason: :invalid_programmer_request}} =
             Programmer.variable_status_request([])

    assert {:error, %Error{reason: :invalid_programmer_request}} =
             Programmer.variable_status_request(
               List.duplicate(address(:markers, :byte, []), 0x10000)
             )
  end

  test "rejects malformed service envelopes, indications, and item records" do
    assert {:error, %Error{reason: :malformed_response}} =
             Programmer.decode_service_data(<<0, 2, 0, 1, 0>>, :programmer_diagnostic)

    assert {:error, %Error{reason: :malformed_response}} =
             Programmer.decode_service_data(<<0, 0, 0>>, :programmer_diagnostic)

    job = %Job{
      service: :variable_status,
      subfunction: 2,
      sequence: 2,
      setup_parameters: <<>>,
      setup_data: <<>>
    }

    indication = decoded_userdata("programmer/variable_status_indication.bin")
    wrong_sequence = put_in(indication.parameter.sequence, 3)

    assert {:error,
            %Error{
              reason: :malformed_response,
              details: %{expected_sequence: 2, received_sequence: 3}
            }} = Programmer.decode_indication(wrong_sequence, job, :variable_status)

    wrong_transport = put_in(indication.payload.transport_size, 4)

    assert {:error, %Error{reason: :malformed_response}} =
             Programmer.decode_indication(wrong_transport, job, :variable_status)

    event = %ProgrammerEvent{
      service: :variable_status,
      subfunction: 2,
      sequence: 2,
      parameters: <<>>,
      data: <<1::16, 0xFF, 9, 2::16, 1>>,
      raw: <<>>
    }

    assert {:error, %Error{reason: :malformed_response}} =
             Programmer.decode_variable_status(event, [address(:markers, :word, byte_offset: 0)])

    bad_padding = %{event | data: <<1::16, 0xFF, 9, 1::16, 1, 0xFF>>}

    assert {:error, %Error{reason: :malformed_response, details: %{padding: <<0xFF>>}}} =
             Programmer.decode_variable_status(
               bad_padding,
               [address(:markers, :byte, byte_offset: 0)]
             )
  end

  test "retains PLC item errors without failing the complete sample" do
    address = address(:markers, :word, byte_offset: 0)

    event = %ProgrammerEvent{
      service: :variable_status,
      subfunction: 2,
      sequence: 2,
      parameters: <<>>,
      data: <<1::16, 0x05, 0, 0::16>>,
      raw: <<>>
    }

    assert {:ok,
            %VariableStatus{
              items: [
                %Item{
                  return_code: 0x05,
                  value: nil,
                  error: %Error{reason: :address_out_of_range}
                }
              ]
            }} = Programmer.decode_variable_status(event, [address])
  end

  test "validates bounded runtime options" do
    assert Programmer.validate_options([], :variable_status) ==
             {:ok, %{timeout: 5_000, step_timeout: 5_000}}

    assert Programmer.validate_options([timeout: 100, step_timeout: 20], :variable_status) ==
             {:ok, %{timeout: 100, step_timeout: 20}}

    for opts <- [[unknown: 1], [timeout: 0], [step_timeout: :infinity], [:invalid], :invalid] do
      assert {:error, %Error{reason: reason}} =
               Programmer.validate_options(opts, :variable_status)

      assert reason in [:invalid_option, :invalid_options]
    end
  end

  defp variable_addresses do
    [
      address(:markers, :byte, byte_offset: 0, count: 6),
      address(:inputs, :byte, byte_offset: 8)
    ]
  end

  defp address(area, data_type, opts) do
    struct!(
      Address,
      Keyword.merge(
        [area: area, data_type: data_type, db_number: 0, count: 1],
        opts
      )
    )
  end

  defp decoded_pdu(path) do
    binary = Fixture.read!(path)
    assert {:ok, pdu, <<>>} = PDU.decode(binary)
    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == binary
    pdu
  end

  defp decoded_userdata(path) do
    assert {:ok, userdata} = path |> decoded_pdu() |> UserData.from_pdu()
    userdata
  end

  defp encoded(message, reference) do
    assert {:ok, pdu} = UserData.to_pdu(message, reference)
    pdu |> PDU.encode() |> IO.iodata_to_binary()
  end
end
