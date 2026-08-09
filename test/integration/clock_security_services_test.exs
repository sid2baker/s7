defmodule S7.ClockSecurityServicesIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Client, Error, PLCClock}
  alias S7.Test.MockPLC

  test "reads, sets, and reads back timezone-free PLC time" do
    server = start_server(clock: ~N[2024-08-09 12:34:56.123])
    assert {:ok, client} = connect(server)

    assert {:ok,
            %PLCClock{
              datetime: ~N[2024-08-09 12:34:56.123],
              reserved: 0,
              century_hint: 0x19
            }} = Client.read_clock(client)

    new_time = ~N[2030-02-03 04:05:06.789]
    assert Client.set_clock(client, new_time) == :ok
    assert {:ok, %PLCClock{datetime: ^new_time}} = Client.read_clock(client)

    assert {:error, %Error{layer: :client, reason: :invalid_clock_value}} =
             Client.set_clock(client, ~N[2030-02-03 04:05:06.000001])

    assert %{state: :ready, in_flight_requests: 0} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "authenticates and logs out without retaining a password in public state or errors" do
    server = start_server(session_password: "TESTONLY")
    assert {:ok, client} = connect(server)
    assert %{authenticated: false} = Client.info(client)

    secret = "PRIVATE"

    assert {:error,
            %Error{
              operation: :authenticate,
              reason: :invalid_password,
              code: 0xD602,
              details: %{}
            } = error} = Client.authenticate(client, secret)

    refute inspect(error) =~ secret
    assert %{state: :ready, authenticated: false} = Client.info(client)

    assert Client.authenticate(client, "TESTONLY") == :ok
    assert %{state: :ready, authenticated: true} = Client.info(client)

    assert Client.logout(client) == :ok
    assert %{state: :ready, authenticated: false} = Client.info(client)

    assert {:error, %Error{reason: :not_authenticated, code: 0xD604}} =
             Client.logout(client)

    assert %{state: :ready} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "authentication is a queue barrier even when multiple jobs were negotiated" do
    server =
      start_server(
        negotiated_jobs: 2,
        notify_requests: true,
        read_response_delay: 100,
        session_password: "TESTONLY"
      )

    assert {:ok, client} = connect(server, max_jobs: 2)

    first_read = Task.async(fn -> Client.read(client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    authentication = Task.async(fn -> Client.authenticate(client, "TESTONLY") end)
    assert %{queued_requests: 1, in_flight_requests: 1} = await_queue(client, 1)

    second_read = Task.async(fn -> Client.read(client, "DB1.DBW0") end)
    assert %{queued_requests: 2, in_flight_requests: 1} = await_queue(client, 2)
    refute_receive {:mock_plc_request, :authenticate, _reference}, 30

    assert Task.await(first_read) == {:ok, 1234}
    assert_receive {:mock_plc_request, :authenticate, _reference}, 500
    refute_receive {:mock_plc_request, :read, _reference}, 30

    assert Task.await(authentication) == :ok
    assert_receive {:mock_plc_request, :read, _reference}, 500
    assert Task.await(second_read) == {:ok, 1234}
    assert %{authenticated: true, queued_requests: 0, in_flight_requests: 0} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "authentication barriers preserve the configured queue bound" do
    server =
      start_server(
        negotiated_jobs: 2,
        notify_requests: true,
        read_response_delay: 100,
        session_password: "TESTONLY"
      )

    assert {:ok, client} = connect(server, max_jobs: 2, queue_limit: 1)

    first_read = Task.async(fn -> Client.read(client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    authentication = Task.async(fn -> Client.authenticate(client, "TESTONLY") end)
    assert %{queued_requests: 1, in_flight_requests: 1} = await_queue(client, 1)

    assert {:error, %Error{reason: :queue_full, details: %{limit: 1}}} =
             Client.read(client, "DB1.DBW0")

    assert Task.await(first_read) == {:ok, 1234}
    assert Task.await(authentication) == :ok
    assert %{authenticated: true, queued_requests: 0, in_flight_requests: 0} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "a completed login updates session state even if its caller exits" do
    server =
      start_server(
        notify_requests: true,
        security_response_delay: 50,
        session_password: "TESTONLY"
      )

    assert {:ok, client} = connect(server)
    caller = spawn(fn -> Client.authenticate(client, "TESTONLY") end)
    assert_receive {:mock_plc_request, :authenticate, _reference}, 500
    Process.exit(caller, :kill)

    assert %{authenticated: true} = await_authenticated(client, true)
    assert Client.logout(client) == :ok
    assert Client.close(client) == :ok
  end

  test "malformed clock responses disconnect and session loss clears authentication state" do
    clock_server = start_server(clock_fault: :malformed_timestamp)
    assert {:ok, clock_client} = connect(clock_server)

    assert {:error, %Error{operation: :read_clock, reason: :malformed_response}} =
             Client.read_clock(clock_client)

    assert %{state: :disconnected} = Client.info(clock_client)
    assert Client.close(clock_client) == :ok

    security_server = start_server(read_fault: :remote_disconnect, session_password: "TESTONLY")
    assert {:ok, security_client} = connect(security_server)
    assert Client.authenticate(security_client, "TESTONLY") == :ok
    assert %{authenticated: true} = Client.info(security_client)

    assert {:error, %Error{reason: :remote_disconnect}} =
             Client.read(security_client, "DB1.DBW0")

    assert %{state: :disconnected, authenticated: false} = Client.info(security_client)
    assert Client.close(security_client) == :ok
  end

  test "invalid credentials fail before entering the request queue" do
    server = start_server()
    assert {:ok, client} = connect(server)

    for invalid <- ["", "123456789", "line\nbreak", <<0>>, :invalid] do
      assert {:error, %Error{layer: :client, reason: :invalid_session_password}} =
               Client.authenticate(client, invalid)
    end

    assert %{state: :ready, authenticated: false, queued_requests: 0, in_flight_requests: 0} =
             Client.info(client)

    assert Client.close(client) == :ok
  end

  defp connect(server, opts \\ []) do
    Client.connect(
      {127, 0, 0, 1},
      Keyword.merge([port: server.port, timeout: 1_000], opts)
    )
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_queue(client, expected, attempts \\ 100)

  defp await_queue(client, expected, attempts) when attempts > 0 do
    case Client.info(client) do
      %{queued_requests: ^expected} = info -> info
      _other -> Process.sleep(5) && await_queue(client, expected, attempts - 1)
    end
  end

  defp await_queue(client, _expected, 0), do: Client.info(client)

  defp await_authenticated(client, expected, attempts \\ 100)

  defp await_authenticated(client, expected, attempts) when attempts > 0 do
    case Client.info(client) do
      %{authenticated: ^expected} = info -> info
      _other -> Process.sleep(5) && await_authenticated(client, expected, attempts - 1)
    end
  end

  defp await_authenticated(client, _expected, 0), do: Client.info(client)
end
