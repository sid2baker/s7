defmodule S7.CyclicServicesIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Client, Cyclic, Error}
  alias S7.Cyclic.Event.Item
  alias S7.Test.MockPLC

  @dbread <<0x12, 0x07, 0xB0, 1, 5, 0, 0x51, 1, 0x72>>
  @dbread_modified <<
    0x12,
    0x11,
    0xB0,
    3,
    5,
    0,
    0x51,
    1,
    0x72,
    0x1D,
    0,
    0x83,
    0,
    0x3C,
    0x16,
    0,
    0x83,
    1,
    0x3E
  >>

  test "runs a typed pull subscription alongside ordinary requests" do
    server =
      start_server(
        notify_requests: true,
        cyclic_values: [<<0x04, 0xD2>>],
        cyclic_push_count: 2
      )

    assert {:ok, client} = connect(server)

    assert {:ok,
            %Cyclic.Subscription{
              job_id: 1,
              mode: :cyclic,
              typed?: true,
              initial: %Cyclic.Event{items: [%Item{value: 1234}]}
            } = subscription} = Client.subscribe_cyclic(client, ["MW10"], queue_limit: 4)

    assert_receive {:mock_plc_request, :cyclic_subscribe, _reference}, 500

    assert %{state: :ready, subscriptions: 1, exclusive_transaction: false} =
             Client.info(client)

    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}

    assert {:ok, %Cyclic.Event{items: [%Item{value: 1234, error: nil}]}} =
             Client.next_cyclic(client, subscription, 500)

    assert {:ok, %Cyclic.Event{items: [%Item{value: 1234}]}} =
             Client.next_cyclic(client, subscription, 500)

    assert Client.unsubscribe_cyclic(client, subscription) == :ok
    assert_receive {:mock_plc_request, :cyclic_unsubscribe, _reference}, 500

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             Client.info(client)

    assert {:error, %Error{reason: :invalid_subscription, operation: :next_cyclic}} =
             Client.next_cyclic(client, subscription, 10)

    assert Client.close(client) == :ok
  end

  test "preserves change-driven records across setup and modification" do
    server =
      start_server(
        notify_requests: true,
        cyclic_change_values: [<<0xFF, 0x43, 0xF6, 0x90, 0x35, 0x60>>],
        cyclic_push_count: 1
      )

    assert {:ok, client} = connect(server)

    assert {:ok,
            %Cyclic.Subscription{
              mode: :change_driven,
              typed?: false,
              initial: %Cyclic.Event{items: [%Item{transport_size: 9, value: nil}]}
            } = subscription} =
             Client.subscribe_cyclic_raw(client, :change_driven, [@dbread])

    assert {:ok, %Cyclic.Event{items: [%Item{data: <<0xFF, 0x43, _rest::binary>>}]}} =
             Client.next_cyclic(client, subscription, 500)

    assert {:ok,
            %Cyclic.Subscription{
              job_id: 1,
              item_specs: [@dbread_modified],
              initial: %Cyclic.Event{items: [%Item{value: nil}]}
            } = modified} =
             Client.modify_cyclic_raw(client, subscription, [@dbread_modified])

    assert_receive {:mock_plc_request, :cyclic_modify, _reference}, 500

    assert {:ok, %Cyclic.Event{subfunction: 7, items: [%Item{value: nil}]}} =
             Client.next_cyclic(client, modified, 500)

    assert Client.unsubscribe_cyclic(client, modified) == :ok
    assert Client.close(client) == :ok
  end

  test "keeps a complete setup rejection session-safe" do
    server = start_server(cyclic_fault: :setup_rejected)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             Client.subscribe_cyclic(client, ["MW10"])

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             Client.info(client)

    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(client) == :ok
  end

  test "rejects an oversized setup locally without invalidating the session" do
    server = start_server(notify_requests: true, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :pdu_too_large}} =
             Client.subscribe_cyclic(client, List.duplicate("MW10", 30))

    refute_receive {:mock_plc_request, :cyclic_subscribe, _reference}, 30

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             Client.info(client)

    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(client) == :ok
  end

  test "invalidates ambiguous setup outcomes and removes provisional subscriptions" do
    for {fault, expected} <- [
          {:setup_silence, :transaction_timeout},
          {:malformed_setup, :malformed_response}
        ] do
      server = start_server(cyclic_fault: fault, cyclic_push_count: 0)
      assert {:ok, client} = connect(server)

      assert {:error, %Error{reason: ^expected}} =
               Client.subscribe_cyclic(client, ["MW10"], timeout: 100, step_timeout: 500)

      assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert Client.close(client) == :ok
    end
  end

  test "keeps the existing job after a complete modification rejection" do
    server = start_server(cyclic_fault: :modify_rejected, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = Client.subscribe_cyclic_raw(client, :change_driven, [@dbread])

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             Client.modify_cyclic_raw(client, subscription, [@dbread_modified])

    assert %{state: :ready, subscriptions: 1, exclusive_transaction: false} =
             Client.info(client)

    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.unsubscribe_cyclic(client, subscription) == :ok
    assert Client.close(client) == :ok
  end

  test "bounds wrong-sequence and malformed indications without crashing" do
    for {fault, expected} <- [
          {:wrong_cyclic_sequence, :timeout},
          {:malformed_indication, :malformed_response}
        ] do
      server = start_server(cyclic_fault: fault, cyclic_push_count: 1)
      assert {:ok, client} = connect(server)
      assert {:ok, subscription} = Client.subscribe_cyclic(client, ["MW10"])

      assert {:error, %Error{reason: ^expected}} =
               Client.next_cyclic(client, subscription, 100)

      assert Client.unsubscribe_cyclic(client, subscription) == :ok
      assert %{state: :ready, subscriptions: 0} = Client.info(client)
      assert Client.close(client) == :ok
    end
  end

  test "reports bounded queue overflow and still tears down the remote job" do
    server = start_server(cyclic_push_count: 3, cyclic_push_delay: 100)
    assert {:ok, client} = connect(server)

    assert {:ok, subscription} =
             Client.subscribe_cyclic(client, ["MW10"], queue_limit: 1)

    Process.sleep(150)

    assert {:error, %Error{reason: :subscription_overflow, details: %{limit: 1}}} =
             Client.next_cyclic(client, subscription, 100)

    assert Client.unsubscribe_cyclic(client, subscription) == :ok
    assert %{state: :ready, subscriptions: 0} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "invalidates an ambiguous session when unsubscribe is rejected" do
    server = start_server(cyclic_fault: :unsubscribe_rejected, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = Client.subscribe_cyclic(client, ["MW10"])

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             Client.unsubscribe_cyclic(client, subscription)

    assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
             await_state(client, :disconnected)

    assert Client.close(client) == :ok
  end

  test "invalidates ambiguous unsubscribe outcomes" do
    for {fault, expected} <- [
          {:unsubscribe_silence, :transaction_timeout},
          {:malformed_unsubscribe, :malformed_response}
        ] do
      server = start_server(cyclic_fault: fault, cyclic_push_count: 0)
      assert {:ok, client} = connect(server)
      assert {:ok, subscription} = Client.subscribe_cyclic(client, ["MW10"])

      assert {:error, %Error{reason: ^expected}} =
               Client.unsubscribe_cyclic(client, subscription,
                 timeout: 100,
                 step_timeout: 500
               )

      assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert Client.close(client) == :ok
    end
  end

  test "closes the session when a remote-backed subscription owner dies" do
    server = start_server(cyclic_push_count: 0)
    assert {:ok, client} = connect(server)
    parent = self()

    owner =
      spawn(fn ->
        result = Client.subscribe_cyclic(client, ["MW10"])
        send(parent, {:cyclic_owner, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:cyclic_owner, ^owner, {:ok, %Cyclic.Subscription{}}}, 500
    assert %{subscriptions: 1} = Client.info(client)
    Process.exit(owner, :kill)

    assert %{state: :disconnected, subscriptions: 0} = await_state(client, :disconnected)
    assert Client.close(client) == :ok
  end

  test "validates intervals, raw specs, modes, handles, and ownership" do
    server = start_server(notify_requests: true, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)

    for {addresses, opts} <- [
          {[], []},
          {["MW10"], [interval: 1_050]},
          {["MW10"], [queue_limit: 0]},
          {["bad"], []}
        ] do
      assert {:error, %Error{}} = Client.subscribe_cyclic(client, addresses, opts)
    end

    assert {:error, %Error{reason: :unsupported_cyclic_mode}} =
             Client.subscribe_cyclic_raw(client, :unknown, [@dbread])

    assert {:error, %Error{reason: :invalid_cyclic_item}} =
             Client.subscribe_cyclic_raw(client, :change_driven, [<<0x12, 1, 0xB0>>])

    refute_receive {:mock_plc_request, :cyclic_subscribe, _reference}, 30

    assert {:ok, subscription} = Client.subscribe_cyclic(client, ["MW10"])

    non_owner = Task.async(fn -> Client.next_cyclic(client, subscription, 10) end)
    assert {:error, %Error{reason: :invalid_subscription}} = Task.await(non_owner)

    assert {:error, %Error{reason: :invalid_cyclic_subscription}} =
             Client.unsubscribe_cyclic(self(), subscription)

    assert Client.unsubscribe_cyclic(client, subscription) == :ok
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
