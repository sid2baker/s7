defmodule S7.ProgrammerServicesIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Client, Error, Programmer}
  alias S7.Programmer.VariableStatus.Item
  alias S7.Test.MockPLC

  test "samples typed variable status and deletes the temporary remote job" do
    server = start_server(notify_requests: true)
    assert {:ok, client} = connect(server)

    marker_bytes = %Address{
      area: :markers,
      byte_offset: 0,
      data_type: :byte,
      count: 6
    }

    assert {:ok,
            %Programmer.VariableStatus{
              sequence: 2,
              parameters: <<1, 0, 0, 2>>,
              items: [
                %Item{
                  address: ^marker_bytes,
                  value: [0x41, 0x33, 0x85, 0x1F, 0xDE, 0xAD],
                  data: <<0x41, 0x33, 0x85, 0x1F, 0xDE, 0xAD>>,
                  error: nil
                },
                %Item{value: 2, data: <<2>>, padding: <<0>>, error: nil}
              ],
              raw: raw
            }} = Client.variable_status(client, [marker_bytes, "IB8"])

    assert byte_size(raw) == 26
    assert_receive {:mock_plc_request, :programmer_setup, _reference}, 500
    assert_receive {:mock_plc_request, :programmer_enable, _reference}, 500
    assert_receive {:mock_plc_request, :programmer_delete, _reference}, 500

    assert %{state: :ready, exclusive_transaction: false, subscriptions: 0} = Client.info(client)
    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(client) == :ok
  end

  test "returns raw records for an evidence-backed diagnostic service" do
    event_data = <<0x00, 0x07, 0x11, 0x22, 0x33, 0x44>>

    server =
      start_server(
        programmer_event_parameters: <<1, 0, 0, 2>>,
        programmer_event_data: event_data
      )

    assert {:ok, client} = connect(server)

    assert {:ok,
            %Programmer.Event{
              service: :block_status_v2,
              subfunction: 0x13,
              sequence: 2,
              parameters: <<1, 0, 0, 2>>,
              data: ^event_data,
              raw: <<4::16, 6::16, 1, 0, 0, 2, ^event_data::binary>>
            }} =
             Client.programmer_diagnostic_raw(
               client,
               :block_status_v2,
               <<0::224>>,
               <<0::224>>
             )

    assert %{state: :ready, exclusive_transaction: false, subscriptions: 0} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "keeps complete setup rejection usable" do
    server = start_server(programmer_fault: :setup_rejected)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             Client.variable_status(client, ["MB0"])

    assert %{state: :ready, exclusive_transaction: false, subscriptions: 0} = Client.info(client)
    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(client) == :ok
  end

  test "deletes a job after indication timeout or malformed indication" do
    for {fault, expected_reason} <- [
          {:silence_indication, :timeout},
          {:wrong_programmer_sequence, :timeout},
          {:malformed_indication, :malformed_response}
        ] do
      server = start_server(programmer_fault: fault, notify_requests: true)
      assert {:ok, client} = connect(server)

      assert {:error, %Error{reason: ^expected_reason}} =
               Client.variable_status(client, ["MB0"], step_timeout: 200)

      assert_receive {:mock_plc_request, :programmer_setup, _reference}, 500
      assert_receive {:mock_plc_request, :programmer_enable, _reference}, 500
      assert_receive {:mock_plc_request, :programmer_delete, _reference}, 500

      assert %{state: :ready, exclusive_transaction: false, subscriptions: 0} =
               Client.info(client)

      assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
      assert Client.close(client) == :ok
    end
  end

  test "invalidates the session when remote job deletion is rejected" do
    server = start_server(programmer_fault: :delete_rejected)
    assert {:ok, client} = connect(server)

    assert {:error,
            %Error{
              reason: :access_denied,
              code: 0xD241,
              details: %{outcome: :sample_received_cleanup_failed}
            }} = Client.variable_status(client, ["MB0"])

    assert %{state: :disconnected, exclusive_transaction: false, subscriptions: 0} =
             await_state(client, :disconnected)

    assert Client.close(client) == :ok
  end

  test "queues ordinary requests until the programmer job is deleted" do
    server =
      start_server(
        programmer_indication_delay: 100,
        notify_requests: true
      )

    assert {:ok, client} = connect(server)
    status = Task.async(fn -> Client.variable_status(client, ["MB0"]) end)
    assert_receive {:mock_plc_request, :programmer_enable, _reference}, 500

    read = Task.async(fn -> Client.read(client, "DB1.DBW0") end)
    assert %{exclusive_transaction: true, queued_requests: 1} = await_queue(client)

    assert {:ok, %Programmer.VariableStatus{}} = Task.await(status)
    assert Task.await(read) == {:ok, 1234}
    assert Client.close(client) == :ok
  end

  test "validates public inputs before reserving the connection" do
    server = start_server(notify_requests: true)
    assert {:ok, client} = connect(server)

    for {service, parameters, data, opts} <- [
          {:force, <<>>, <<>>, []},
          {0x09, <<>>, <<>>, []},
          {:block_status, :invalid, <<>>, []},
          {:block_status, <<>>, :invalid, []},
          {:block_status, <<>>, <<>>, [timeout: 0]}
        ] do
      assert {:error, %Error{}} =
               Client.programmer_diagnostic_raw(client, service, parameters, data, opts)
    end

    assert {:error, %Error{reason: :invalid_items}} = Client.variable_status(client, [])
    assert {:error, %Error{}} = Client.variable_status(client, ["L0.0"])
    refute_receive {:mock_plc_request, :programmer_setup, _reference}, 30

    assert %{state: :ready, exclusive_transaction: false} = Client.info(client)
    assert Client.close(client) == :ok
  end

  defp connect(server) do
    Client.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)
  end

  defp start_server(opts) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_queue(client, attempts \\ 50)
  defp await_queue(client, 0), do: Client.info(client)

  defp await_queue(client, attempts) do
    case Client.info(client) do
      %{queued_requests: 1} = info ->
        info

      _info ->
        Process.sleep(5)
        await_queue(client, attempts - 1)
    end
  end

  defp await_state(client, expected, attempts \\ 50)
  defp await_state(client, _expected, 0), do: Client.info(client)

  defp await_state(client, expected, attempts) do
    case Client.info(client) do
      %{state: ^expected} = info ->
        info

      _info ->
        Process.sleep(5)
        await_state(client, expected, attempts - 1)
    end
  end
end
