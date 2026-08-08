defmodule S7.ClientIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Client, Error}
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

  test "a wrong PDU reference is structured and does not crash the connection" do
    server = start_server(read_fault: :wrong_reference)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{layer: :s7, reason: :unexpected_pdu_reference}} =
             Client.read(client, "DB1.DBW0")

    assert Process.alive?(client)
    assert %{state: :ready} = Client.info(client)
    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(client) == :ok
  end

  test "a truncated service payload does not crash the connection" do
    server = start_server(read_fault: :truncated_payload)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)

    assert {:error, %Error{layer: :s7, reason: :malformed_response}} =
             Client.read(client, "DB1.DBW0")

    assert Process.alive?(client)
    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
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
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end
end
