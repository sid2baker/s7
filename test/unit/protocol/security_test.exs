defmodule S7.Protocol.SecurityTest do
  use ExUnit.Case, async: true

  alias S7.{Error, SessionPassword}
  alias S7.Protocol.{PDU, Security, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}
  alias S7.Test.Fixture

  test "obfuscates a padded non-secret test password" do
    assert {:ok, password} = SessionPassword.new("TESTONLY")

    assert Security.encode_password(password) ==
             <<0x01, 0x10, 0x07, 0x11, 0x1D, 0x0A, 0x04, 0x06>>

    assert {:ok, request} = Security.login_request(password)

    assert %UserData{
             parameter: %Parameter{function_group: :security, subfunction: 1},
             payload: %Payload{return_code: 0xFF, transport_size: 9, data: data}
           } = request

    assert data == Security.encode_password(password)
    refute inspect(password) =~ "TESTONLY"
  end

  test "decodes the credential-free captured login response" do
    assert {:ok, password} = SessionPassword.new("TESTONLY")
    assert {:ok, request} = Security.login_request(password)
    fixture = Fixture.read!("security/login_response.bin")
    assert {:ok, pdu, <<>>} = PDU.decode(fixture)

    assert Security.decode_response(pdu, request, 0x0600) == {:ok, :ok}
    assert pdu |> PDU.encode() |> IO.iodata_to_binary() == fixture
  end

  test "encodes logout without credential data" do
    assert {:ok,
            %UserData{
              parameter: %Parameter{function_group: :security, subfunction: 2},
              payload: %Payload{return_code: 0x0A, transport_size: 0, data: <<>>}
            }} = Security.logout_request()
  end

  test "maps classic password errors without credential details" do
    assert {:ok, password} = SessionPassword.new("TESTONLY")
    assert {:ok, request} = Security.login_request(password)

    for {code, reason} <- [
          {0xD241, :access_denied},
          {0xD602, :invalid_password},
          {0xD604, :already_authenticated},
          {0xD605, :password_not_configured},
          {0xD601, :userdata_error}
        ] do
      assert {:ok, pdu} = response_pdu(request, error_code: code)

      assert {:error, %Error{reason: ^reason, code: ^code, details: details}} =
               Security.decode_response(pdu, request, 1)

      assert details == %{}
    end

    assert {:ok, logout} = Security.logout_request()
    assert {:ok, pdu} = response_pdu(logout, error_code: 0xD604)

    assert {:error, %Error{reason: :not_authenticated, code: 0xD604}} =
             Security.decode_response(pdu, logout, 1)
  end

  test "rejects malformed null responses and invalid credentials" do
    assert {:error, %Error{reason: :invalid_session_password}} =
             Security.login_request(:invalid)

    assert {:ok, password} = SessionPassword.new("TESTONLY")
    assert {:ok, request} = Security.login_request(password)
    assert {:ok, pdu} = response_pdu(request, return_code: 0xFF, transport_size: 9)

    assert {:error, %Error{reason: :malformed_response}} =
             Security.decode_response(pdu, request, 1)
  end

  defp response_pdu(request, opts) do
    response = %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :response,
        function_group: :security,
        subfunction: request.parameter.subfunction,
        sequence: 0,
        data_unit_reference: 1,
        last_data_unit: 0,
        error_code: Keyword.get(opts, :error_code, 0)
      },
      payload: %Payload{
        return_code: Keyword.get(opts, :return_code, 0x0A),
        transport_size: Keyword.get(opts, :transport_size, 0),
        data: <<>>
      }
    }

    UserData.to_pdu(response, 1)
  end
end
