defmodule S7.PublicAPIIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{
    Address,
    Error,
    PLC,
    Result,
    SZL
  }

  alias S7.Connection
  alias S7.Protocol.UserData
  alias S7.Test.MockPLC
  alias S7.Transport.COTP.{DisconnectConfirm, DisconnectRequest}

  test "connects, negotiates, reads, writes, verifies, and disconnects" do
    server = start_server(cotp_fragment_responses: true, negotiated_pdu: 240)

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1}, port: server.port, rack: 0, slot: 2, timeout: 1_000)

    assert {:ok,
            %{
              state: :ready,
              pdu_size: 240,
              max_jobs: 1,
              tpdu_size: 1024
            }} = S7.info(client)

    assert S7.read(client, "DB1.DBX0.0") == {:ok, true}
    assert S7.read(client, "DB1.DBB1") == {:ok, 0xA5}
    assert S7.read(client, "DB1.DBW2") == {:ok, 0x1234}
    assert S7.read(client, "DB1.DBD4") == {:ok, 0x01020304}
    assert S7.read_raw(client, "DB1.DBW0") == {:ok, <<0x04, 0xD2>>}

    assert S7.read(client, "I0.0") == {:ok, true}
    assert S7.read(client, "IB0") == {:ok, 0x11}
    assert S7.read(client, "IW0") == {:ok, 0x1122}
    assert S7.read(client, "Q0.0") == {:ok, false}
    assert S7.read(client, "QB0") == {:ok, 0x22}
    assert S7.read(client, "QW0") == {:ok, 0x2233}
    assert S7.read(client, "M10.0") == {:ok, false}
    assert S7.read(client, "MB10") == {:ok, 0x33}
    assert S7.read(client, "MW10") == {:ok, 0x3344}
    assert S7.read(client, "MD10") == {:ok, 0x33445566}

    assert S7.write(client, "DB1.DBW0", 4321) == :ok
    assert S7.read(client, "DB1.DBW0") == {:ok, 4321}
    assert S7.write(client, "M10.0", true) == :ok
    assert S7.read(client, "M10.0") == {:ok, true}
    assert S7.write(client, "QW0", 0xCAFE) == :ok
    assert S7.read(client, "QW0") == {:ok, 0xCAFE}

    real_address = %Address{
      area: :db,
      db_number: 1,
      byte_offset: 20,
      data_type: :real
    }

    assert S7.write(client, real_address, 12.5) == :ok
    assert S7.read(client, real_address) == {:ok, 12.5}

    assert S7.close(client) == :ok

    assert_receive {:mock_plc_disconnect_request,
                    %DisconnectRequest{
                      destination_reference: 1,
                      source_reference: 1,
                      reason: 0x80
                    }},
                   1_000

    assert_receive :mock_plc_closed, 1_000
    assert {:error, %Error{reason: :connection_closed}} = S7.read(client, "DB1.DBW0")
  end

  test "accepts TCP FIN and bounds a silent COTP disconnect" do
    fin_server = start_server(disconnect_behavior: :fin)
    assert {:ok, fin_client} = S7.connect({127, 0, 0, 1}, port: fin_server.port)
    assert S7.close(fin_client, timeout: 100) == :ok
    assert_receive {:mock_plc_disconnect_request, %DisconnectRequest{reason: 0x80}}, 500

    silent_server = start_server(disconnect_behavior: :silence)
    assert {:ok, silent_client} = S7.connect({127, 0, 0, 1}, port: silent_server.port)
    monitor = Process.monitor(silent_client)

    started_at = System.monotonic_time(:millisecond)
    assert S7.close(silent_client, timeout: 20) == :ok
    elapsed = System.monotonic_time(:millisecond) - started_at

    assert elapsed >= 15
    assert elapsed < 500
    assert_normal_exit(silent_client, monitor)
  end

  test "falls back to socket close for invalid COTP close responses" do
    for behavior <- [:invalid_confirm, :error] do
      server = start_server(disconnect_behavior: behavior)
      assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)
      monitor = Process.monitor(client)

      assert S7.close(client, timeout: 100) == :ok
      assert_receive {:mock_plc_disconnect_request, %DisconnectRequest{}}, 500
      assert_receive :mock_plc_closed, 500
      assert_normal_exit(client, monitor)
    end
  end

  test "answers a peer disconnect request and preserves its diagnostic" do
    server = start_server(read_fault: :remote_disconnect)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:error,
            %Error{
              layer: :cotp,
              reason: :remote_disconnect,
              code: 0x80,
              details: %{additional_information: "maintenance"}
            }} = S7.read(client, "DB1.DBW0")

    assert_receive {:mock_plc_disconnect_confirm,
                    %DisconnectConfirm{destination_reference: 1, source_reference: 1}},
                   500

    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "distinguishes COTP error and unexpected disconnect-confirm TPDUs" do
    for {fault, reason, code} <- [
          {:error_tpdu, :protocol_error, 2},
          {:disconnect_confirm, :unexpected_disconnect_confirm, nil}
        ] do
      server = start_server(read_fault: fault)
      assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

      assert {:error, %Error{layer: :cotp, reason: ^reason, code: ^code}} =
               S7.read(client, "DB1.DBW0")

      assert %{state: :disconnected} = S7.TestSupport.info!(client)
      assert S7.close(client) == :ok
    end
  end

  test "a wrong PDU reference invalidates the session without crashing its owner" do
    server = start_server(read_fault: :wrong_reference)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{layer: :s7, reason: :unexpected_pdu_reference}} =
             S7.read(client, "DB1.DBW0")

    assert Process.alive?(client)
    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert {:error, %Error{reason: :not_connected}} = S7.read(client, "DB1.DBW0")
    assert S7.close(client) == :ok
  end

  test "routes correlated userdata without letting an indication consume the request" do
    server = start_server(userdata_fault: :indication_before_response)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)
    assert {:ok, request} = UserData.request(:cpu, 1, <<0x00, 0x11, 0x00, 0x00>>)

    assert {:ok, %UserData{payload: %{data: <<0x00, 0x11, 0x00, 0x00>>}}} =
             Connection.userdata(client, request)

    assert %{state: :ready, in_flight_requests: 0} = S7.TestSupport.info!(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "userdata parameter errors preserve their raw code and the session" do
    server = start_server(userdata_fault: :parameter_error)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)
    assert {:ok, request} = UserData.request(:cpu, 1, <<>>)

    assert {:error, %Error{operation: :read_szl, reason: :userdata_error, code: 0xD041}} =
             Connection.userdata(client, request, :read_szl)

    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "a mismatched userdata service invalidates the session" do
    server = start_server(userdata_fault: :wrong_service)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)
    assert {:ok, request} = UserData.request(:cpu, 1, <<>>)

    assert {:error, %Error{reason: :unexpected_userdata_service}} =
             Connection.userdata(client, request)

    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "reads fragmented SZLs and exposes documented metadata helpers" do
    server = start_server(szl_fragment_size: 7)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:ok,
            %SZL{
              id: 0x0011,
              record_length: 28,
              record_count: 1,
              records: [<<1::16, _rest::binary>>]
            }} = S7.PLC.read_szl(client, 0x0011)

    assert S7.PLC.list_szl(client) == {:ok, [0x0011, 0x001C, 0x0131, 0x0424]}

    assert {:ok, %PLC.OrderCode{code: "6ES7 315-2EH14-0AB0", version: {3, 2, 1}}} =
             S7.PLC.order_code(client)

    assert {:ok,
            %PLC.CPUInfo{
              automation_system_name: "Test PLC",
              module_name: "CPU 315-2 PN/DP",
              serial_number: "S C-C2UR28922012",
              module_type_name: "CPU 315-2 PN/DP"
            }} = S7.PLC.cpu_info(client)

    assert {:ok, %PLC.CPInfo{max_pdu_length: 480, max_connections: 8}} = S7.PLC.cp_info(client)
    assert {:ok, %PLC.Status{state: :run, code: 8}} = S7.PLC.status(client)
    assert %{state: :ready, in_flight_requests: 0} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  for {fault, reason} <- [
        {:mismatched_id, :malformed_response},
        {:mismatched_data_unit_reference, :malformed_response},
        {:malformed_geometry, :malformed_response},
        {:missing_extension, :malformed_response},
        {:wrong_transport, :malformed_response}
      ] do
    test "SZL fault #{fault} invalidates the transaction and session" do
      server = start_server(szl_fault: unquote(fault), szl_fragment_size: 3)
      assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

      assert {:error, %Error{operation: :read_szl, reason: unquote(reason)}} =
               S7.PLC.read_szl(client, 0x0011)

      assert %{state: :disconnected} = S7.TestSupport.info!(client)
      assert S7.close(client) == :ok
    end
  end

  test "SZL fragment and aggregate bounds invalidate an incomplete transaction" do
    fragment_server = start_server(szl_fragment_size: 1)
    assert {:ok, fragment_client} = S7.connect({127, 0, 0, 1}, port: fragment_server.port)

    assert {:error, %Error{reason: :too_many_userdata_fragments}} =
             S7.PLC.read_szl(fragment_client, 0x0011, max_fragments: 2)

    assert %{state: :disconnected} = S7.TestSupport.info!(fragment_client)
    assert S7.close(fragment_client) == :ok

    size_server = start_server(szl_fragment_size: 7)
    assert {:ok, size_client} = S7.connect({127, 0, 0, 1}, port: size_server.port)

    assert {:error, %Error{reason: :userdata_too_large}} =
             S7.PLC.read_szl(size_client, 0x0011, max_bytes: 8)

    assert %{state: :disconnected} = S7.TestSupport.info!(size_client)
    assert S7.close(size_client) == :ok
  end

  test "a PLC SZL parameter error leaves the session available for Read Var" do
    server = start_server(userdata_fault: :parameter_error)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{operation: :read_szl, reason: :userdata_error, code: 0xD041}} =
             S7.PLC.read_szl(client, 0x0011)

    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "a truncated service payload invalidates the session without crashing its owner" do
    server = start_server(read_fault: :truncated_payload)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{layer: :s7, reason: :malformed_response}} =
             S7.read(client, "DB1.DBW0")

    assert Process.alive?(client)
    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "PLC item errors retain their raw return code" do
    server = start_server()
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{reason: :object_not_found, code: 0x0A}} =
             S7.read(client, "DB99.DBW0")

    assert Process.alive?(client)
    assert S7.close(client) == :ok
  end

  test "a receive timeout disconnects the socket without crashing its owner" do
    server = start_server(read_fault: :silence)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 50)

    assert {:error, %Error{layer: :tcp, reason: :timeout}} = S7.read(client, "DB1.DBW0")
    assert Process.alive?(client)
    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert {:error, %Error{reason: :not_connected}} = S7.read(client, "DB1.DBW0")
    assert S7.close(client) == :ok
  end

  test "invalid connection options fail before opening a socket" do
    assert {:error, %Error{reason: :invalid_rack}} =
             S7.connect({127, 0, 0, 1}, rack: 8)

    assert {:error, %Error{reason: :invalid_tpdu_size}} =
             S7.connect({127, 0, 0, 1}, tpdu_size: 1000)

    assert {:error, %Error{reason: :invalid_host}} = S7.connect({127, 0})
    assert {:error, %Error{reason: :invalid_options}} = S7.connect({127, 0, 0, 1}, :invalid)

    assert {:error, %Error{reason: :invalid_options}} =
             S7.connect({127, 0, 0, 1}, [:invalid])

    assert {:error, %Error{reason: :invalid_option, details: %{option: :prot}}} =
             S7.connect({127, 0, 0, 1}, prot: 102)

    assert {:error, %Error{reason: :invalid_pdu_size}} =
             S7.connect({127, 0, 0, 1}, pdu_size: 31)

    assert {:error, %Error{reason: :invalid_tpkt_size}} =
             S7.connect({127, 0, 0, 1}, max_tpkt_size: 6)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, max_tpkt_size: 1024, receive_buffer_limit: 1000)

    assert {:error, %Error{reason: :invalid_tsap}} =
             S7.connect({127, 0, 0, 1}, src_tsap: <<>>)

    assert {:error, %Error{reason: :invalid_tsap}} =
             S7.connect({127, 0, 0, 1}, dst_tsap: :invalid)

    assert {:error, %Error{reason: :invalid_pdu_reference}} =
             S7.connect({127, 0, 0, 1}, initial_reference: -1)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, max_jobs: 0)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, queue_limit: -1)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, reconnect: :sometimes)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, reconnect_min_delay: 20, reconnect_max_delay: 10)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, reconnect_max_attempts: 0)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, reconnect_jitter: 1.1)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.connect({127, 0, 0, 1}, allow_destructive: :sometimes)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.start_link(host: {127, 0, 0, 1}, name: {:invalid, :name})

    assert {:error, %Error{reason: :missing_host}} = S7.start_link([])
    assert {:error, %Error{reason: :invalid_options}} = S7.start_link([:invalid])
  end

  test "supports hostname strings, explicit TSAPs, and linked connection startup" do
    first = start_server()

    assert {:ok, client} =
             S7.connect("127.0.0.1",
               port: first.port,
               src_tsap: <<1, 1>>,
               dst_tsap: <<1, 2>>
             )

    assert {:error, %Error{reason: :already_connected}} = Connection.connect(client)
    assert S7.close(client) == :ok

    second = start_server()
    assert {:ok, linked} = Connection.start_link(~c"127.0.0.1", port: second.port)
    assert :ok = Connection.connect(linked)
    assert :ok = Connection.close(linked)
  end

  test "starts as a supervised worker and connects after an unavailable endpoint appears" do
    port = reserve_port()
    child_id = {:reconnecting_s7_client, make_ref()}

    client =
      start_supervised!(
        {S7,
         [
           id: child_id,
           host: {127, 0, 0, 1},
           port: port,
           timeout: 500,
           reconnect: true,
           reconnect_min_delay: 10,
           reconnect_max_delay: 20,
           reconnect_jitter: 0
         ]}
      )

    assert %{state: :reconnecting, reconnect: true} = S7.TestSupport.info!(client)
    _server = start_server(port: port)
    assert %{state: :ready, reconnect_attempts: 0} = await_state(client, :ready)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert :ok = stop_supervised(child_id)
  end

  test "reconnects after session loss without replaying an indeterminate write" do
    first_server = start_server(write_fault: :close_after_write)

    assert {:ok, client} =
             S7.start_link(
               host: {127, 0, 0, 1},
               port: first_server.port,
               timeout: 100,
               reconnect: true,
               reconnect_min_delay: 10,
               reconnect_max_delay: 20,
               reconnect_jitter: 0
             )

    on_exit(fn ->
      if Process.alive?(client), do: S7.close(client)
    end)

    assert {:error, %Error{reason: :connection_closed}} =
             S7.write(client, "DB1.DBW0", 4321)

    assert_receive :mock_plc_closed, 500
    _second_server = start_server(port: first_server.port)

    assert %{state: :ready} = await_state(client, :ready)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "caps reconnect attempts and permits an explicit fresh attempt" do
    port = reserve_port()

    assert {:ok, client} =
             S7.start_link(
               host: {127, 0, 0, 1},
               port: port,
               timeout: 500,
               reconnect: true,
               reconnect_min_delay: 5,
               reconnect_max_delay: 5,
               reconnect_max_attempts: 2,
               reconnect_jitter: 0
             )

    assert %{state: :disconnected, reconnect_attempts: 2} =
             await_state(client, :disconnected)

    _server = start_server(port: port)
    assert S7.reconnect(client) == :ok
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "supports registered supervised client names" do
    server = start_server()
    name = {:global, {__MODULE__, make_ref()}}

    assert {:ok, client} =
             S7.start_link(host: {127, 0, 0, 1}, port: server.port, name: name)

    monitor = Process.monitor(client)
    assert %{state: :ready} = S7.TestSupport.info!(name)
    assert S7.read(name, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(name) == :ok
    assert_normal_exit(client, monitor)
  end

  test "correlates concurrent responses that arrive out of order" do
    server =
      start_server(
        negotiated_jobs: 2,
        reverse_read_groups: 2,
        notify_requests: true
      )

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1}, port: server.port, max_jobs: 2, timeout: 1_000)

    first = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    second = Task.async(fn -> S7.read(client, "DB1.DBB1") end)

    assert_receive {:mock_plc_request, :read, first_reference}, 500
    assert_receive {:mock_plc_request, :read, second_reference}, 500
    refute first_reference == second_reference

    assert Task.await(first) == {:ok, 1234}
    assert Task.await(second) == {:ok, 0xA5}

    assert %{
             max_jobs: 2,
             in_flight_requests: 0,
             queued_requests: 0,
             socket_mode: :active_once
           } = S7.TestSupport.info!(client)

    assert S7.close(client) == :ok
  end

  test "bounds the caller queue while a request is in flight" do
    server = start_server(read_fault: :silence, notify_requests: true)

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1},
               port: server.port,
               queue_limit: 1,
               timeout: 1_000
             )

    first = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    second = Task.async(fn -> S7.read(client, "DB1.DBW2") end)
    assert %{queued_requests: 1, in_flight_requests: 1} = await_queue(client, 1)

    assert {:error, %Error{layer: :client, reason: :queue_full, details: %{limit: 1}}} =
             S7.read(client, "DB1.DBB1")

    assert S7.close(client) == :ok
    assert {:error, %Error{reason: :connection_closed}} = Task.await(first)
    assert {:error, %Error{reason: :connection_closed}} = Task.await(second)
  end

  test "drains accepted work and rejects new work before closing" do
    server = start_server(read_response_delay: 100, notify_requests: true)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 500)
    monitor = Process.monitor(client)

    read = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    close = Task.async(fn -> S7.close(client, mode: :drain, timeout: 500) end)
    assert %{state: :draining, in_flight_requests: 1} = await_state(client, :draining)

    assert {:error, %Error{reason: :not_connected, details: %{state: :draining}}} =
             S7.read(client, "DB1.DBW2")

    assert Task.await(read) == {:ok, 1234}
    assert Task.await(close) == :ok
    assert_normal_exit(client, monitor)
  end

  test "bounds drain time and returns structured errors to accepted work" do
    server = start_server(read_fault: :silence, notify_requests: true)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)
    monitor = Process.monitor(client)

    read = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    assert {:error, %Error{operation: :close, reason: :drain_timeout}} =
             S7.close(client, mode: :drain, timeout: 20)

    assert {:error, %Error{operation: :read, reason: :drain_timeout}} = Task.await(read)
    assert_normal_exit(client, monitor)
  end

  test "validates close options without disturbing the session" do
    server = start_server()
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{operation: :close, reason: :invalid_options}} =
             S7.close(client, mode: :later)

    assert {:error, %Error{operation: :close, reason: :invalid_options}} =
             S7.close(client, timeout: 0)

    assert {:error, %Error{operation: :close, reason: :invalid_options}} =
             S7.close(client, [:invalid])

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client, mode: :drain) == :ok
  end

  test "consumes an in-flight response after its caller exits" do
    server =
      start_server(
        negotiated_jobs: 2,
        reverse_read_groups: 2,
        notify_requests: true
      )

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1}, port: server.port, max_jobs: 2, timeout: 1_000)

    caller = spawn(fn -> S7.read(client, "DB1.DBW0") end)
    monitor = Process.monitor(caller)
    assert_receive {:mock_plc_request, :read, _reference}, 500
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 500

    assert S7.read(client, "DB1.DBB1") == {:ok, 0xA5}

    assert %{state: :ready, in_flight_requests: 0, queued_requests: 0} =
             S7.TestSupport.info!(client)

    assert S7.close(client) == :ok
  end

  test "removes queued work when its caller exits" do
    server = start_server(read_fault: :silence, notify_requests: true)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    in_flight = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    caller = spawn(fn -> S7.read(client, "DB1.DBW2") end)
    monitor = Process.monitor(caller)
    assert %{queued_requests: 1} = await_queue(client, 1)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 500
    assert %{queued_requests: 0, in_flight_requests: 1} = await_queue(client, 0)

    assert S7.close(client) == :ok
    assert {:error, %Error{reason: :connection_closed}} = Task.await(in_flight)
  end

  test "connection refusal and dead clients return structured errors" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, %Error{layer: :tcp, reason: :connection_refused}} =
             S7.connect({127, 0, 0, 1}, port: port, timeout: 100)

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}
    assert S7.close(dead) == :ok
    assert {:error, %Error{reason: :connection_closed}} = S7.info(dead)
  end

  test "local request validation does not disturb a ready connection" do
    server = start_server()
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{layer: :address, reason: :invalid_address}} = S7.read(client, 123)

    assert {:error, %Error{layer: :data, reason: :value_out_of_range}} =
             S7.write(client, "DB1.DBW0", -1)

    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "reads and writes typed arrays and raw byte ranges" do
    server = start_server()
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    words = %Address{area: :db, db_number: 1, byte_offset: 100, data_type: :word, count: 3}
    assert :ok = S7.write(client, words, [1, 0x1234, 0xFFFF])
    assert S7.read(client, words) == {:ok, [1, 0x1234, 0xFFFF]}
    assert S7.read_raw(client, words) == {:ok, <<1::16, 0x1234::16, 0xFFFF::16>>}

    bytes = %Address{area: :db, db_number: 1, byte_offset: 120, data_type: :byte, count: 5}
    assert :ok = S7.write_raw(client, bytes, <<1, 2, 3, 4, 5>>)
    assert S7.read_raw(client, bytes) == {:ok, <<1, 2, 3, 4, 5>>}
    assert S7.read(client, bytes) == {:ok, [1, 2, 3, 4, 5]}

    assert {:error, %Error{layer: :data, reason: :raw_size_mismatch}} =
             S7.write_raw(client, bytes, <<1, 2>>)

    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "rejects counted items whose request or response exceeds the negotiated PDU" do
    server = start_server(negotiated_pdu: 240)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    oversized_read = %Address{
      area: :db,
      db_number: 1,
      byte_offset: 0,
      data_type: :byte,
      count: 223
    }

    assert {:error, %Error{reason: :pdu_too_large}} = S7.read(client, oversized_read)

    oversized_write = %{oversized_read | count: 213}

    assert {:error, %Error{reason: :pdu_too_large}} =
             S7.write_raw(client, oversized_write, :binary.copy(<<0>>, 213))

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "multi-read preserves order and per-item PLC errors" do
    server = start_server()
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)
    addresses = ["DB1.DBW0", "DB99.DBW0", "MB10"]

    assert {:ok,
            [
              %Result{status: :ok, value: 1234},
              %Result{status: :error, error: %Error{reason: :object_not_found}},
              %Result{status: :ok, value: 0x33}
            ]} = S7.read_many(client, addresses)

    assert {:ok,
            [
              %Result{status: :ok, value: <<0x04, 0xD2>>},
              %Result{status: :error},
              %Result{status: :ok, value: <<0x33>>}
            ]} = S7.read_many_raw(client, addresses)

    assert S7.close(client) == :ok
  end

  test "multi-write supports typed and raw values with per-item results" do
    server = start_server()
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    words = %Address{area: :db, db_number: 1, byte_offset: 200, data_type: :word, count: 2}
    byte = %Address{area: :markers, byte_offset: 30, data_type: :byte}

    assert {:ok, [%Result{status: :ok}, %Result{status: :ok}]} =
             S7.write_many(client, [{words, [1, 2]}, {byte, 0xA5}])

    assert {:ok, [%Result{value: [1, 2]}, %Result{value: 0xA5}]} =
             S7.read_many(client, [words, byte])

    raw = %Address{area: :db, db_number: 1, byte_offset: 220, data_type: :byte, count: 3}

    assert {:ok, [%Result{status: :ok}]} =
             S7.write_many_raw(client, [{raw, <<1, 2, 3>>}])

    assert S7.read_raw(client, raw) == {:ok, <<1, 2, 3>>}
    assert S7.close(client) == :ok
  end

  test "multi operations split against the negotiated PDU and retain order" do
    server = start_server(negotiated_pdu: 60)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    writes =
      for offset <- 300..304 do
        address = %Address{area: :db, db_number: 1, byte_offset: offset, data_type: :byte}
        {address, offset - 299}
      end

    assert {:ok, write_results} = S7.write_many(client, writes)
    assert Enum.map(write_results, & &1.status) == List.duplicate(:ok, 5)

    addresses = Enum.map(writes, &elem(&1, 0))
    assert {:ok, read_results} = S7.read_many(client, addresses)
    assert Enum.map(read_results, & &1.value) == [1, 2, 3, 4, 5]
    assert Enum.map(read_results, & &1.address) == addresses
    assert %{next_reference: 7} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "outbound S7 PDUs are segmented against the negotiated COTP TPDU size" do
    server = start_server(negotiated_pdu: 240)

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1}, port: server.port, tpdu_size: 128)

    writes =
      for offset <- 400..407 do
        address = %Address{area: :db, db_number: 1, byte_offset: offset * 2, data_type: :word}
        {address, offset}
      end

    assert {:ok, results} = S7.write_many(client, writes)
    assert Enum.map(results, & &1.status) == List.duplicate(:ok, 8)

    addresses = Enum.map(writes, &elem(&1, 0))
    assert {:ok, read_results} = S7.read_many(client, addresses)
    assert Enum.map(read_results, & &1.value) == Enum.to_list(400..407)
    assert S7.close(client) == :ok
  end

  test "receive fragment limits scale with the negotiated PDU and TPDU sizes" do
    server =
      start_server(
        fragment_tcp: false,
        negotiated_pdu: 0xFFFF,
        read_fault: :many_valid_fragments
      )

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1},
               port: server.port,
               pdu_size: 0xFFFF,
               tpdu_size: 128
             )

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert %{state: :ready, pdu_size: 0xFFFF, tpdu_size: 128} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "a stopped multi-read marks its batch failed and later batches not attempted" do
    server = start_server(negotiated_pdu: 60, read_fault: :silence_multi)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 50)

    addresses =
      for offset <- 0..4 do
        %Address{area: :db, db_number: 1, byte_offset: offset, data_type: :byte}
      end

    assert {:error, %Error{reason: :timeout}, results} = S7.read_many(client, addresses)
    assert Enum.map(results, & &1.status) == [:error, :error, :error, :error, :not_attempted]
    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "a stopped multi-write distinguishes indeterminate and not-attempted items" do
    server = start_server(negotiated_pdu: 60, write_fault: :silence_multi)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 50)

    writes =
      for offset <- 0..4 do
        {%Address{area: :db, db_number: 1, byte_offset: offset, data_type: :byte}, offset}
      end

    assert {:error, %Error{reason: :timeout}, results} = S7.write_many(client, writes)

    assert Enum.map(results, & &1.status) == [
             :indeterminate,
             :indeterminate,
             :not_attempted,
             :not_attempted,
             :not_attempted
           ]

    assert %{state: :disconnected} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "multi APIs validate every input before sending" do
    server = start_server(write_fault: :second_item_error)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{reason: :invalid_items}} = S7.read_many(client, [])

    assert {:error, %Error{reason: :invalid_address, details: %{index: 1}}} =
             S7.read_many(client, ["DB1.DBW0", :invalid])

    assert {:error, %Error{reason: :invalid_item}} = S7.write_many(client, [:invalid])

    assert {:error, %Error{reason: :value_out_of_range, details: %{index: 1}}} =
             S7.write_many(client, [{"DB1.DBW0", 1}, {"DB1.DBW2", -1}])

    assert {:ok, [%Result{status: :ok}, %Result{status: :error}]} =
             S7.write_many(client, [{"DB1.DBW0", 1}, {"DB1.DBW2", 2}])

    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  for {fault, reason} <- [
        wrong_reference: :invalid_connection_reference,
        unsupported_class: :unsupported_connection_class,
        unexpected_tpdu: :unexpected_tpdu
      ] do
    test "COTP connection fault #{fault} is rejected" do
      server = start_server(cotp_fault: unquote(fault))

      assert {:error, %Error{layer: :cotp, reason: unquote(reason)}} =
               S7.connect({127, 0, 0, 1}, port: server.port, timeout: 200)
    end
  end

  for {fault, layer, reason} <- [
        {:wrong_reference, :s7, :unexpected_pdu_reference},
        {:header_error, :s7, :protocol_error},
        {:malformed_parameters, :s7, :malformed_response},
        {:nonempty_data, :s7, :malformed_response},
        {:unexpected_tpdu, :cotp, :unexpected_tpdu},
        {:wrong_tpdu_number, :cotp, :unexpected_tpdu_number},
        {:silence, :tcp, :timeout}
      ] do
    test "Setup Communication fault #{fault} is rejected" do
      server = start_server(setup_fault: unquote(fault))

      assert {:error, %Error{layer: unquote(layer), reason: unquote(reason)}} =
               S7.connect({127, 0, 0, 1}, port: server.port, timeout: 50)
    end
  end

  for {fault, layer, reason} <- [
        {:trailing_pdu, :s7, :malformed_response},
        {:truncated_pdu, :s7, :malformed_response},
        {:wrong_tpdu_number, :cotp, :unexpected_tpdu_number},
        {:unexpected_tpdu, :cotp, :unexpected_tpdu},
        {:oversized_reassembly, :s7, :pdu_too_large},
        {:too_many_fragments, :cotp, :too_many_fragments}
      ] do
    test "read transport fault #{fault} disconnects the session" do
      server = start_server(read_fault: unquote(fault), fragment_tcp: false)
      assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port, timeout: 500)

      assert {:error, %Error{layer: unquote(layer), reason: unquote(reason)}} =
               S7.read(client, "DB1.DBW0")

      assert Process.alive?(client)
      assert %{state: :disconnected} = S7.TestSupport.info!(client)
      assert S7.close(client) == :ok
    end
  end

  test "a PLC write error preserves the connection and return code" do
    server = start_server(write_fault: :plc_error)
    assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{reason: :address_out_of_range, code: 0x05}} =
             S7.write(client, "DB1.DBW0", 1)

    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  for {fault, reason} <- [
        malformed_response: :malformed_response,
        wrong_reference: :unexpected_pdu_reference
      ] do
    test "write response fault #{fault} disconnects the session" do
      server = start_server(write_fault: unquote(fault))
      assert {:ok, client} = S7.connect({127, 0, 0, 1}, port: server.port)

      assert {:error, %Error{layer: :s7, reason: unquote(reason)}} =
               S7.write(client, "DB1.DBW0", 1)

      assert %{state: :disconnected} = S7.TestSupport.info!(client)
      assert S7.close(client) == :ok
    end
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_queue(client, expected, attempts \\ 50)

  defp await_queue(client, expected, attempts) when attempts > 0 do
    case S7.TestSupport.info!(client) do
      %{queued_requests: ^expected} = info ->
        info

      _other ->
        Process.sleep(5)
        await_queue(client, expected, attempts - 1)
    end
  end

  defp await_queue(client, _expected, 0), do: S7.TestSupport.info!(client)

  defp await_state(client, expected, attempts \\ 100)

  defp await_state(client, expected, attempts) when attempts > 0 do
    case S7.TestSupport.info!(client) do
      %{state: ^expected} = info ->
        info

      _other ->
        Process.sleep(5)
        await_state(client, expected, attempts - 1)
    end
  end

  defp await_state(client, _expected, 0), do: S7.TestSupport.info!(client)

  defp assert_normal_exit(client, monitor) do
    assert_receive {:DOWN, ^monitor, :process, ^client, :normal}, 1_000
  end

  defp reserve_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end
end
