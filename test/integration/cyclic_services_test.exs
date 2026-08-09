defmodule S7.CyclicServicesIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Cyclic, Error}
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

  test "pushes typed subscription events alongside ordinary requests" do
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
              typed?: true
            } = subscription} = S7.Cyclic.subscribe(client, ["MW10"])

    reference = subscription.reference

    assert_receive {:mock_plc_request, :cyclic_subscribe, _reference}, 500

    assert %{state: :ready, subscriptions: 1, exclusive_transaction: false} =
             S7.TestSupport.info!(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}

    for _event <- 1..3 do
      assert_receive {:s7, ^reference, %Cyclic.Event{items: [%Item{value: 1234, error: nil}]}},
                     500
    end

    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert_receive {:mock_plc_request, :cyclic_unsubscribe, _reference}, 500

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             S7.TestSupport.info!(client)

    assert {:error, %Error{reason: :invalid_subscription}} =
             S7.Cyclic.unsubscribe(subscription)

    assert S7.close(client) == :ok
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
              typed?: false
            } = subscription} =
             S7.Cyclic.subscribe_raw(client, :change_driven, [@dbread])

    reference = subscription.reference

    assert_receive {:s7, ^reference,
                    %Cyclic.Event{items: [%Item{transport_size: 9, value: nil}]}},
                   500

    assert_receive {:s7, ^reference,
                    %Cyclic.Event{items: [%Item{data: <<0xFF, 0x43, _rest::binary>>}]}},
                   500

    assert {:ok,
            %Cyclic.Subscription{
              job_id: 1,
              item_specs: [@dbread_modified]
            } = modified} =
             S7.Cyclic.modify_raw(subscription, [@dbread_modified])

    assert_receive {:mock_plc_request, :cyclic_modify, _reference}, 500

    for _event <- 1..2 do
      assert_receive {:s7, ^reference, %Cyclic.Event{subfunction: 7, items: [%Item{value: nil}]}},
                     500
    end

    assert S7.Cyclic.unsubscribe(modified) == :ok
    assert S7.close(client) == :ok
  end

  test "keeps a complete setup rejection session-safe" do
    server = start_server(cyclic_fault: :setup_rejected)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.Cyclic.subscribe(client, ["MW10"])

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             S7.TestSupport.info!(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "rejects an oversized setup locally without invalidating the session" do
    server = start_server(notify_requests: true, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :pdu_too_large}} =
             S7.Cyclic.subscribe(client, List.duplicate("MW10", 30))

    refute_receive {:mock_plc_request, :cyclic_subscribe, _reference}, 30

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             S7.TestSupport.info!(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "invalidates ambiguous setup outcomes and removes provisional subscriptions" do
    for {fault, expected} <- [
          {:setup_silence, :transaction_timeout},
          {:malformed_setup, :malformed_response}
        ] do
      server = start_server(cyclic_fault: fault, cyclic_push_count: 0)
      assert {:ok, client} = connect(server)

      assert {:error, %Error{reason: ^expected}} =
               S7.Cyclic.subscribe(client, ["MW10"], timeout: 100, step_timeout: 500)

      assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert S7.close(client) == :ok
    end
  end

  test "keeps the existing job after a complete modification rejection" do
    server = start_server(cyclic_fault: :modify_rejected, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = S7.Cyclic.subscribe_raw(client, :change_driven, [@dbread])

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.Cyclic.modify_raw(subscription, [@dbread_modified])

    assert %{state: :ready, subscriptions: 1, exclusive_transaction: false} =
             S7.TestSupport.info!(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert S7.close(client) == :ok
  end

  test "ignores wrong-sequence indications without crashing" do
    server = start_server(cyclic_fault: :wrong_cyclic_sequence, cyclic_push_count: 1)
    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = S7.Cyclic.subscribe(client, ["MW10"])
    reference = subscription.reference

    assert_receive {:s7, ^reference, %Cyclic.Event{}}, 500
    refute_receive {:s7, ^reference, _event}, 100

    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert %{state: :ready, subscriptions: 0} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "reports malformed indications without crashing" do
    server = start_server(cyclic_fault: :malformed_indication, cyclic_push_count: 1)
    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = S7.Cyclic.subscribe(client, ["MW10"])
    reference = subscription.reference

    assert_receive {:s7, ^reference, %Cyclic.Event{}}, 500

    assert_receive {:s7, ^reference,
                    {:error, %Error{operation: :cyclic_event, reason: :malformed_response}}},
                   500

    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert %{state: :ready, subscriptions: 0} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "delivers bursts directly to the owner mailbox" do
    server = start_server(cyclic_push_count: 3, cyclic_push_delay: 100)
    assert {:ok, client} = connect(server)

    assert {:ok, subscription} = S7.Cyclic.subscribe(client, ["MW10"])
    reference = subscription.reference

    for _event <- 1..4 do
      assert_receive {:s7, ^reference, %Cyclic.Event{}}, 500
    end

    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert %{state: :ready, subscriptions: 0} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "supports subscriptions through a registered connection name" do
    server = start_server(cyclic_push_count: 0)
    name = {:global, {__MODULE__, make_ref()}}

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1},
               name: name,
               port: server.port,
               timeout: 1_000
             )

    assert {:ok, %Cyclic.Subscription{connection: ^name} = subscription} =
             S7.Cyclic.subscribe(name, ["MW10"])

    reference = subscription.reference
    assert_receive {:s7, ^reference, %Cyclic.Event{}}, 500
    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert S7.close(client) == :ok
  end

  test "invalidates an ambiguous session when unsubscribe is rejected" do
    server = start_server(cyclic_fault: :unsubscribe_rejected, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = S7.Cyclic.subscribe(client, ["MW10"])

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.Cyclic.unsubscribe(subscription)

    assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
             await_state(client, :disconnected)

    assert S7.close(client) == :ok
  end

  test "invalidates ambiguous unsubscribe outcomes" do
    for {fault, expected} <- [
          {:unsubscribe_silence, :transaction_timeout},
          {:malformed_unsubscribe, :malformed_response}
        ] do
      server = start_server(cyclic_fault: fault, cyclic_push_count: 0)
      assert {:ok, client} = connect(server)
      assert {:ok, subscription} = S7.Cyclic.subscribe(client, ["MW10"])

      assert {:error, %Error{reason: ^expected}} =
               S7.Cyclic.unsubscribe(subscription,
                 timeout: 100,
                 step_timeout: 500
               )

      assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert S7.close(client) == :ok
    end
  end

  test "closes the session when a remote-backed subscription owner dies" do
    server = start_server(cyclic_push_count: 0)
    assert {:ok, client} = connect(server)
    parent = self()

    owner =
      spawn(fn ->
        result = S7.Cyclic.subscribe(client, ["MW10"])
        send(parent, {:cyclic_owner, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:cyclic_owner, ^owner, {:ok, %Cyclic.Subscription{}}}, 500
    assert %{subscriptions: 1} = S7.TestSupport.info!(client)
    Process.exit(owner, :kill)

    assert %{state: :disconnected, subscriptions: 0} = await_state(client, :disconnected)
    assert S7.close(client) == :ok
  end

  test "validates intervals, raw specs, modes, handles, and ownership" do
    server = start_server(notify_requests: true, cyclic_push_count: 0)
    assert {:ok, client} = connect(server)

    for {addresses, opts} <- [
          {[], []},
          {["MW10"], [interval: 1_050]},
          {["MW10"], [queue_limit: 1]},
          {["bad"], []}
        ] do
      assert {:error, %Error{}} = S7.Cyclic.subscribe(client, addresses, opts)
    end

    assert {:error, %Error{reason: :unsupported_cyclic_mode}} =
             S7.Cyclic.subscribe_raw(client, :unknown, [@dbread])

    assert {:error, %Error{reason: :invalid_cyclic_item}} =
             S7.Cyclic.subscribe_raw(client, :change_driven, [<<0x12, 1, 0xB0>>])

    refute_receive {:mock_plc_request, :cyclic_subscribe, _reference}, 30

    assert {:ok, subscription} = S7.Cyclic.subscribe(client, ["MW10"])

    non_owner = Task.async(fn -> S7.Cyclic.unsubscribe(subscription) end)
    assert {:error, %Error{reason: :invalid_subscription}} = Task.await(non_owner)

    assert {:error, %Error{reason: :invalid_cyclic_subscription}} =
             S7.Cyclic.unsubscribe(:not_a_subscription)

    assert S7.Cyclic.unsubscribe(subscription) == :ok
    assert S7.close(client) == :ok
  end

  defp connect(server) do
    S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)
  end

  defp start_server(opts) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_state(client, expected, attempts \\ 50)
  defp await_state(client, _expected, 0), do: S7.TestSupport.info!(client)

  defp await_state(client, expected, attempts) do
    case S7.TestSupport.info!(client) do
      %{state: ^expected} = info ->
        info

      _info ->
        Process.sleep(5)
        await_state(client, expected, attempts - 1)
    end
  end
end
