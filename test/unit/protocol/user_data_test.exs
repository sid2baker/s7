defmodule S7.Protocol.UserDataTest do
  use ExUnit.Case, async: true

  alias S7.Error
  alias S7.Protocol.PDU
  alias S7.Protocol.UserData
  alias S7.Protocol.UserData.{Parameter, Payload}
  alias S7.Test.Fixture

  @reference 42

  test "encodes and decodes the canonical initial Read SZL envelope" do
    fixture = Fixture.read!("userdata/read_szl_request.bin")

    assert {:ok, request} = UserData.request(:cpu, 0x01, <<0x00, 0x11, 0x00, 0x00>>)
    assert {:ok, pdu} = UserData.to_pdu(request, @reference)
    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == fixture

    assert {:ok, decoded_pdu, <<>>} = PDU.decode(fixture)
    assert UserData.from_pdu(decoded_pdu) == {:ok, request}
  end

  test "decodes an extended response and validates its request identity" do
    fixture = Fixture.read!("userdata/read_szl_response.bin")

    assert {:ok, request} = UserData.request(:cpu, 0x01, <<0x00, 0x11, 0x00, 0x00>>)
    assert {:ok, pdu, <<>>} = PDU.decode(fixture)

    assert {:ok,
            %UserData{
              parameter: %Parameter{
                type: :response,
                function_group: :cpu,
                subfunction: 1,
                sequence: 0,
                data_unit_reference: 3,
                last_data_unit: 0,
                error_code: 0
              },
              payload: %Payload{
                data: <<0x00, 0x11, 0x00, 0x00, 0x00, 0x02, 0x00, 0x01, 0x00, 0x01>>
              }
            }} = UserData.decode_response(pdu, request, @reference)

    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == fixture
  end

  test "round-trips continuation parameters" do
    parameter = %Parameter{
      method: 0x12,
      type: :request,
      function_group: :cpu,
      subfunction: 1,
      sequence: 7,
      data_unit_reference: 0,
      last_data_unit: 0,
      error_code: 0
    }

    fixture = <<0, 1, 0x12, 8, 0x12, 0x44, 1, 7, 0, 0, 0, 0>>

    assert UserData.encode_parameter(parameter) == {:ok, fixture}
    assert UserData.decode_parameter(fixture) == {:ok, parameter}
  end

  test "encodes the canonical Read SZL continuation PDU" do
    fixture = Fixture.read!("userdata/read_szl_continuation.bin")

    assert {:ok, continuation} =
             UserData.request(:cpu, 1, <<>>,
               method: 0x12,
               sequence: 7,
               data_unit_reference: 0,
               last_data_unit: 0,
               error_code: 0,
               return_code: 0x0A,
               transport_size: 0
             )

    assert {:ok, pdu} = UserData.to_pdu(continuation, 43)
    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == fixture
    assert {:ok, decoded, <<>>} = PDU.decode(fixture)
    assert UserData.from_pdu(decoded) == {:ok, continuation}
  end

  test "retains unknown function groups" do
    fixture = <<0, 1, 0x12, 4, 0x11, 0x7E, 0xAA, 0x55>>

    assert {:ok, %Parameter{type: :request, function_group: 0x3E}} =
             UserData.decode_parameter(fixture)

    assert {:ok, parameter} = UserData.decode_parameter(fixture)
    assert UserData.encode_parameter(parameter) == {:ok, fixture}
  end

  test "reports malformed parameter and payload boundaries" do
    assert {:error, %Error{reason: :invalid_userdata}} =
             UserData.request(:cpu, 1, <<>>, :not_options)

    assert {:error,
            %Error{
              reason: :invalid_option,
              details: %{option: :sequnce, value: 1}
            }} = UserData.request(:cpu, 1, <<>>, sequnce: 1)

    assert UserData.decode_parameter(<<>>) == {:more, 4}
    assert UserData.decode_parameter(<<0, 1, 0x12, 4, 0x11>>) == {:more, 3}

    assert UserData.decode_parameter(<<0, 1, 0x12, 5, 0, 0, 0, 0, 0>>) ==
             {:error, :malformed_userdata_parameter}

    assert UserData.decode_parameter(<<0, 1, 0x12, 4, 0x11, 0x44, 1, 0, 0>>) ==
             {:error, :malformed_userdata_parameter}

    assert UserData.decode_parameter(<<0, 1, 0x12, 4, 0x11, 0xC4, 1, 0>>) ==
             {:error, :unsupported_userdata_type}

    assert UserData.decode_payload(<<0xFF>>) == {:more, 3}
    assert UserData.decode_payload(<<0xFF, 9, 0, 2, 1>>) == {:more, 1}

    assert UserData.decode_payload(<<0xFF, 9, 0, 1, 1, 2>>) ==
             {:error, :trailing_userdata_payload}

    invalid_extension = %Parameter{
      method: 0x11,
      type: :request,
      function_group: :cpu,
      subfunction: 1,
      sequence: 0,
      data_unit_reference: 1
    }

    assert UserData.encode_parameter(invalid_extension) ==
             {:error, :invalid_userdata_parameter}
  end

  test "turns response identity and PLC status failures into structured errors" do
    assert {:ok, request} = UserData.request(:cpu, 1, <<>>)

    response = fn parameter, payload ->
      %UserData{parameter: parameter, payload: payload}
      |> UserData.to_pdu(@reference)
      |> elem(1)
    end

    base_parameter = %Parameter{
      method: 0x12,
      type: :response,
      function_group: :cpu,
      subfunction: 1,
      sequence: 0,
      data_unit_reference: 0,
      last_data_unit: 0,
      error_code: 0
    }

    success_payload = %Payload{data: <<>>}

    assert {:error, %Error{reason: :unexpected_pdu_reference}} =
             UserData.decode_response(
               response.(base_parameter, success_payload),
               request,
               @reference + 1
             )

    assert {:error, %Error{reason: :unexpected_userdata_type}} =
             UserData.decode_response(
               response.(%{base_parameter | type: :request}, success_payload),
               request,
               @reference
             )

    assert {:error, %Error{reason: :unexpected_userdata_service}} =
             UserData.decode_response(
               response.(%{base_parameter | subfunction: 2}, success_payload),
               request,
               @reference
             )

    assert {:error, %Error{reason: :userdata_error, code: 0xD041}} =
             UserData.decode_response(
               response.(%{base_parameter | error_code: 0xD041}, success_payload),
               request,
               @reference
             )

    assert {:error, %Error{reason: :object_not_found, code: 0x0A}} =
             UserData.decode_response(
               response.(base_parameter, %{success_payload | return_code: 0x0A}),
               request,
               @reference
             )
  end
end
