defmodule S7.ClientIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Client, Error}
  alias S7.Connection
  alias S7.Test.MockPLC

  test "connects, negotiates, reads, writes, verifies, and disconnects" do
    server = start_server(cotp_fragment_responses: true, negotiated_pdu: 240)

    assert {:ok, client} =
             Client.connect({127, 0, 0, 1}, port: server.port, rack: 0, slot: 2, timeout: 1_000)

    assert %{
             state: :ready,
             pdu_size: 240,
             max_jobs: 1,
             tpdu_size: 1024
           } = Client.info(client)

    assert Client.read(client, "DB1.DBX0.0") == {:ok, true}
    assert Client.read(client, "DB1.DBB1") == {:ok, 0xA5}
    assert Client.read(client, "DB1.DBW2") == {:ok, 0x1234}
    assert Client.read(client, "DB1.DBD4") == {:ok, 0x01020304}
    assert Client.read_raw(client, "DB1.DBW0") == {:ok, <<0x04, 0xD2>>}

    assert Client.read(client, "I0.0") == {:ok, true}
    assert Client.read(client, "IB0") == {:ok, 0x11}
    assert Client.read(client, "IW0") == {:ok, 0x1122}
    assert Client.read(client, "Q0.0") == {:ok, false}
    assert Client.read(client, "QB0") == {:ok, 0x22}
    assert Client.read(client, "QW0") == {:ok, 0x2233}
    assert Client.read(client, "M10.0") == {:ok, false}
    assert Client.read(client, "MB10") == {:ok, 0x33}
    assert Client.read(client, "MW10") == {:ok, 0x3344}
    assert Client.read(client, "MD10") == {:ok, 0x33445566}

    assert Client.write(client, "DB1.DBW0", 4321) == :ok
    assert Client.read(client, "DB1.DBW0") == {:ok, 4321}
    assert Client.write(client, "M10.0", true) == :ok
    assert Client.read(client, "M10.0") == {:ok, true}
    assert Client.write(client, "QW0", 0xCAFE) == :ok
    assert Client.read(client, "QW0") == {:ok, 0xCAFE}

    real_address = %Address{
      area: :db,
      db_number: 1,
      byte_offset: 20,
      data_type: :real
    }

    assert Client.write(client, real_address, 12.5) == :ok
    assert Client.read(client, real_address) == {:ok, 12.5}

    assert Client.close(client) == :ok
    assert_receive :mock_plc_closed, 1_000
    assert {:error, %Error{reason: :connection_closed}} = Client.read(client, "DB1.DBW0")
  end

  test "a wrong PDU reference invalidates the session without crashing its owner" do
    server = start_server(read_fault: :wrong_reference)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{layer: :s7, reason: :unexpected_pdu_reference}} =
             Client.read(client, "DB1.DBW0")

    assert Process.alive?(client)
    assert %{state: :disconnected} = Client.info(client)
    assert {:error, %Error{reason: :not_connected}} = Client.read(client, "DB1.DBW0")
    assert Client.close(client) == :ok
  end

  test "a truncated service payload invalidates the session without crashing its owner" do
    server = start_server(read_fault: :truncated_payload)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{layer: :s7, reason: :malformed_response}} =
             Client.read(client, "DB1.DBW0")

    assert Process.alive?(client)
    assert %{state: :disconnected} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "PLC item errors retain their raw return code" do
    server = start_server()
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{reason: :object_not_found, code: 0x0A}} =
             Client.read(client, "DB99.DBW0")

    assert Process.alive?(client)
    assert Client.close(client) == :ok
  end

  test "a receive timeout disconnects the socket without crashing its owner" do
    server = start_server(read_fault: :silence)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 50)

    assert {:error, %Error{layer: :tcp, reason: :timeout}} = Client.read(client, "DB1.DBW0")
    assert Process.alive?(client)
    assert %{state: :disconnected} = Client.info(client)
    assert {:error, %Error{reason: :not_connected}} = Client.read(client, "DB1.DBW0")
    assert Client.close(client) == :ok
  end

  test "invalid connection options fail before opening a socket" do
    assert {:error, %Error{reason: :invalid_rack}} =
             Client.connect({127, 0, 0, 1}, rack: 8)

    assert {:error, %Error{reason: :invalid_tpdu_size}} =
             Client.connect({127, 0, 0, 1}, tpdu_size: 1000)

    assert {:error, %Error{reason: :invalid_host}} = Client.connect({127, 0})
    assert {:error, %Error{reason: :invalid_options}} = Client.connect({127, 0, 0, 1}, :invalid)

    assert {:error, %Error{reason: :invalid_pdu_size}} =
             Client.connect({127, 0, 0, 1}, pdu_size: 31)

    assert {:error, %Error{reason: :invalid_tpkt_size}} =
             Client.connect({127, 0, 0, 1}, max_tpkt_size: 6)

    assert {:error, %Error{reason: :invalid_option}} =
             Client.connect({127, 0, 0, 1}, max_tpkt_size: 1024, receive_buffer_limit: 1000)

    assert {:error, %Error{reason: :invalid_tsap}} =
             Client.connect({127, 0, 0, 1}, src_tsap: <<>>)

    assert {:error, %Error{reason: :invalid_tsap}} =
             Client.connect({127, 0, 0, 1}, dst_tsap: :invalid)

    assert {:error, %Error{reason: :invalid_pdu_reference}} =
             Client.connect({127, 0, 0, 1}, initial_reference: -1)
  end

  test "supports hostname strings, explicit TSAPs, and linked connection startup" do
    first = start_server()

    assert {:ok, client} =
             Client.connect("127.0.0.1",
               port: first.port,
               src_tsap: <<1, 1>>,
               dst_tsap: <<1, 2>>
             )

    assert {:error, %Error{reason: :already_connected}} = Connection.connect(client)
    assert Client.close(client) == :ok

    second = start_server()
    assert {:ok, linked} = Connection.start_link(~c"127.0.0.1", port: second.port)
    assert :ok = Connection.connect(linked)
    assert :ok = Connection.close(linked)
  end

  test "connection refusal and dead clients return structured errors" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, %Error{layer: :tcp, reason: :connection_refused}} =
             Client.connect({127, 0, 0, 1}, port: port, timeout: 100)

    dead = spawn(fn -> :ok end)
    monitor = Process.monitor(dead)
    assert_receive {:DOWN, ^monitor, :process, ^dead, :normal}
    assert Client.close(dead) == :ok
    assert {:error, %Error{reason: :connection_closed}} = Client.info(dead)
  end

  test "local request validation does not disturb a ready connection" do
    server = start_server()
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{layer: :address, reason: :invalid_address}} = Client.read(client, 123)

    assert {:error, %Error{layer: :data, reason: :value_out_of_range}} =
             Client.write(client, "DB1.DBW0", -1)

    assert %{state: :ready} = Client.info(client)
    assert Client.close(client) == :ok
  end

  for {fault, reason} <- [
        wrong_reference: :invalid_connection_reference,
        unsupported_class: :unsupported_connection_class,
        unexpected_tpdu: :unexpected_tpdu
      ] do
    test "COTP connection fault #{fault} is rejected" do
      server = start_server(cotp_fault: unquote(fault))

      assert {:error, %Error{layer: :cotp, reason: unquote(reason)}} =
               Client.connect({127, 0, 0, 1}, port: server.port, timeout: 200)
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
               Client.connect({127, 0, 0, 1}, port: server.port, timeout: 50)
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
      server = start_server(read_fault: unquote(fault))
      assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 500)

      assert {:error, %Error{layer: unquote(layer), reason: unquote(reason)}} =
               Client.read(client, "DB1.DBW0")

      assert Process.alive?(client)
      assert %{state: :disconnected} = Client.info(client)
      assert Client.close(client) == :ok
    end
  end

  test "a PLC write error preserves the connection and return code" do
    server = start_server(write_fault: :plc_error)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port)

    assert {:error, %Error{reason: :address_out_of_range, code: 0x05}} =
             Client.write(client, "DB1.DBW0", 1)

    assert %{state: :ready} = Client.info(client)
    assert Client.close(client) == :ok
  end

  for {fault, reason} <- [
        malformed_response: :malformed_response,
        wrong_reference: :unexpected_pdu_reference
      ] do
    test "write response fault #{fault} disconnects the session" do
      server = start_server(write_fault: unquote(fault))
      assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port)

      assert {:error, %Error{layer: :s7, reason: unquote(reason)}} =
               Client.write(client, "DB1.DBW0", 1)

      assert %{state: :disconnected} = Client.info(client)
      assert Client.close(client) == :ok
    end
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end
end
