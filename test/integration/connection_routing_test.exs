defmodule S7.ConnectionRoutingIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Client, Connection, Error}
  alias S7.Protocol.{PDU, UserData}
  alias S7.Test.MockPLC

  test "reserves a bidirectional transaction and releases queued work in order" do
    server = start_server(notify_requests: true)
    client = connect(server)

    assert {:ok, token} = Connection.begin_transaction(client, :test_transaction)
    queued_read = Task.async(fn -> Client.read(client, "DB1.DBW0") end)
    assert %{exclusive_transaction: true, queued_requests: 1} = await_queue(client, 1)

    request = PDU.new(:job, 0, <<0xEE, 0x01>>)

    assert {:ok, %PDU{parameters: <<0xEE, 0x01>>, data: "transaction-response"}} =
             Connection.transaction_request(client, token, request)

    assert {:ok,
            %PDU{
              header: %{rosctr: :job, pdu_reference: server_reference},
              parameters: <<0xEE, 0x02, 1>>,
              data: <<1>>
            }} = Connection.transaction_receive(client, token)

    reply = PDU.new(:ack_data, server_reference, <<0xEE, 0x03>>)
    assert Connection.transaction_reply(client, token, reply) == :ok
    assert_receive {:mock_plc_transaction_reply, ^server_reference}, 500

    assert Connection.end_transaction(client, token) == :ok
    assert Task.await(queued_read) == {:ok, 1234}
    assert %{exclusive_transaction: false, queued_requests: 0} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "bounds transaction traffic and unsolicited Job buffering" do
    message_server = start_server()
    message_client = connect(message_server)

    assert {:ok, token} =
             Connection.begin_transaction(message_client, :bounded, maximum_messages: 2)

    assert {:error, %Error{reason: :transaction_limit_exceeded}} =
             Connection.transaction_request(
               message_client,
               token,
               PDU.new(:job, 0, <<0xEE, 0x01>>)
             )

    assert %{state: :disconnected} = Client.info(message_client)
    assert Client.close(message_client) == :ok

    inbox_server = start_server(transaction_jobs: 2)
    inbox_client = connect(inbox_server)
    assert {:ok, token} = Connection.begin_transaction(inbox_client, :bounded, inbox_limit: 1)

    assert {:error, %Error{reason: :transaction_inbox_overflow}} =
             Connection.transaction_request(
               inbox_client,
               token,
               PDU.new(:job, 0, <<0xEE, 0x01>>)
             )

    assert %{state: :disconnected} = Client.info(inbox_client)
    assert Client.close(inbox_client) == :ok
  end

  test "bounds transaction waits and disconnects when its owner dies" do
    server = start_server()
    client = connect(server)
    assert {:ok, token} = Connection.begin_transaction(client, :bounded)

    assert {:error, %Error{reason: :timeout}} =
             Connection.transaction_receive(client, token, 10)

    assert %{state: :ready, exclusive_transaction: true} = Client.info(client)
    assert Connection.end_transaction(client, token) == :ok

    parent = self()

    owner =
      spawn(fn ->
        result = Connection.begin_transaction(client, :owner_lifecycle)
        send(parent, {:transaction_owner, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:transaction_owner, ^owner, {:ok, _token}}, 500
    Process.exit(owner, :kill)

    assert %{state: :disconnected} = await_state(client, :disconnected)
    assert Client.close(client) == :ok
  end

  test "lets an accepted transaction finish while graceful close drains" do
    server = start_server()
    client = connect(server)
    assert {:ok, token} = Connection.begin_transaction(client, :drain_transaction)

    close = Task.async(fn -> Client.close(client, mode: :drain, timeout: 500) end)
    assert %{state: :draining, exclusive_transaction: true} = await_state(client, :draining)
    assert Connection.end_transaction(client, token) == :ok
    assert Task.await(close) == :ok
  end

  test "routes matching userdata indications into a monitored pull subscription" do
    server = start_server(userdata_fault: :indication_before_response)
    client = connect(server)

    assert {:ok, subscription} =
             Connection.subscribe_userdata(client, %{function_group: :cpu, subfunction: 3})

    assert {:ok, request} = UserData.request(:cpu, 1, <<0x00, 0x11, 0x00, 0x00>>)
    assert {:ok, %UserData{}} = Connection.userdata(client, request)

    assert {:ok,
            %UserData{
              parameter: %{type: :indication, function_group: :cpu, subfunction: 3},
              payload: %{data: "event1"}
            }} = Connection.next_userdata(client, subscription)

    assert Connection.unsubscribe_userdata(client, subscription) == :ok
    assert %{subscriptions: 0, state: :ready} = Client.info(client)
    assert Client.close(client) == :ok
  end

  test "isolates subscription overflow and removes subscriptions with their owners" do
    overflow_server =
      start_server(userdata_fault: :indication_before_response, indication_count: 2)

    overflow_client = connect(overflow_server)

    assert {:ok, subscription} =
             Connection.subscribe_userdata(overflow_client, %{}, queue_limit: 1)

    assert {:ok, request} = UserData.request(:cpu, 1, <<>>)
    assert {:ok, %UserData{}} = Connection.userdata(overflow_client, request)

    assert {:error, %Error{reason: :subscription_overflow, details: %{limit: 1}}} =
             Connection.next_userdata(overflow_client, subscription)

    assert %{state: :ready} = Client.info(overflow_client)
    assert Client.read(overflow_client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(overflow_client) == :ok

    owner_server = start_server()
    owner_client = connect(owner_server)
    parent = self()

    owner =
      spawn(fn ->
        result = Connection.subscribe_userdata(owner_client, %{})
        send(parent, {:subscription_owner, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:subscription_owner, ^owner, {:ok, _subscription}}, 500
    assert %{subscriptions: 1} = Client.info(owner_client)
    Process.exit(owner, :kill)
    assert %{subscriptions: 0} = await_subscriptions(owner_client, 0)
    assert Client.close(owner_client) == :ok
  end

  test "validates transaction and subscription ownership and bounds" do
    server = start_server()

    assert {:ok, client} =
             Client.connect({127, 0, 0, 1}, port: server.port, subscription_limit: 1)

    assert {:error, %Error{reason: :invalid_options}} =
             Connection.begin_transaction(client, :test, [:invalid])

    assert {:error, %Error{reason: :invalid_filter}} =
             Connection.subscribe_userdata(client, %{function_group: :unknown})

    assert {:ok, subscription} = Connection.subscribe_userdata(client, %{})

    assert {:error, %Error{reason: :subscription_limit, details: %{limit: 1}}} =
             Connection.subscribe_userdata(client, %{})

    assert {:error, %Error{reason: :invalid_timeout}} =
             Connection.next_userdata(client, subscription, 0)

    assert Connection.unsubscribe_userdata(client, subscription) == :ok
    assert Client.close(client) == :ok
  end

  test "rejects invalid transaction options, ownership, and PDU directions locally" do
    server = start_server()
    client = connect(server)

    for opts <- [
          [unknown: 1],
          [timeout: 0],
          [step_timeout: 0],
          [maximum_messages: 0],
          [maximum_bytes: 0],
          [inbox_limit: 0]
        ] do
      assert {:error, %Error{reason: :invalid_option}} =
               Connection.begin_transaction(client, :validation, opts)
    end

    assert {:error, %Error{reason: :invalid_options}} =
             Connection.begin_transaction(client, "validation", [])

    assert {:ok, token} = Connection.begin_transaction(client, :validation)

    assert {:error, %Error{reason: :transaction_busy}} =
             Connection.begin_transaction(client, :second)

    assert {:error, %Error{reason: :invalid_transaction_pdu}} =
             Connection.transaction_request(client, token, PDU.new(:ack_data, 0, <<>>))

    assert {:error, %Error{reason: :invalid_transaction_pdu}} =
             Connection.transaction_reply(client, token, PDU.new(:job, 0, <<>>))

    assert {:error, %Error{reason: :pdu_too_large}} =
             Connection.transaction_reply(
               client,
               token,
               PDU.new(:ack_data, 0, <<>>, :binary.copy(<<0>>, 500))
             )

    non_owner = Task.async(fn -> Connection.end_transaction(client, token) end)
    assert {:error, %Error{reason: :invalid_transaction}} = Task.await(non_owner)

    assert {:error, %Error{reason: :invalid_transaction}} =
             Connection.end_transaction(client, make_ref())

    assert Connection.end_transaction(client, token) == :ok
    assert Client.close(client) == :ok
  end

  test "requires PLC-initiated Jobs to be consumed before transaction release" do
    server = start_server()
    client = connect(server)
    assert {:ok, token} = Connection.begin_transaction(client, :incomplete)

    assert {:ok, %PDU{}} =
             Connection.transaction_request(client, token, PDU.new(:job, 0, <<0xEE, 0x01>>))

    assert {:error,
            %Error{
              reason: :transaction_incomplete,
              details: %{inbox_count: 1, receive_pending: false}
            }} = Connection.end_transaction(client, token)

    assert {:ok, %PDU{}} = Connection.transaction_receive(client, token)
    assert Connection.end_transaction(client, token) == :ok
    assert Client.close(client) == :ok
  end

  test "bounds both pending reservation and active transaction lifetimes" do
    waiting_server = start_server(read_response_delay: 100, notify_requests: true)
    waiting_client = connect(waiting_server)
    read = Task.async(fn -> Client.read(waiting_client, "DB1.DBW0") end)
    assert_receive {:mock_plc_request, :read, _reference}, 500

    owner =
      Task.async(fn ->
        Connection.begin_transaction(waiting_client, :waiting_transaction, timeout: 20)
      end)

    assert {:error, %Error{reason: :transaction_timeout}} = Task.await(owner)
    assert Task.await(read) == {:ok, 1234}
    assert %{state: :ready, transaction_waiting: false} = Client.info(waiting_client)
    assert Client.close(waiting_client) == :ok

    active_server = start_server()
    active_client = connect(active_server)

    assert {:ok, _token} =
             Connection.begin_transaction(active_client, :active_transaction, timeout: 20)

    assert %{state: :disconnected} = await_state(active_client, :disconnected)
    assert Client.close(active_client) == :ok
  end

  test "validates subscription filters and keeps timed-out subscriptions usable" do
    server = start_server()
    client = connect(server)

    for filter <- [
          :all,
          %{unknown: 1},
          %{function_group: :unknown},
          %{subfunction: 256},
          %{sequence: 256},
          %{type: :unknown}
        ] do
      assert {:error, %Error{reason: :invalid_filter}} =
               Connection.subscribe_userdata(client, filter)
    end

    for opts <- [[:invalid], [unknown: 1], [queue_limit: 0]] do
      assert {:error, %Error{reason: reason}} =
               Connection.subscribe_userdata(client, %{}, opts)

      assert reason in [:invalid_options, :invalid_option]
    end

    assert {:ok, subscription} =
             Connection.subscribe_userdata(client, %{
               function_group: 4,
               subfunction: :any,
               type: :indication
             })

    assert {:error, %Error{reason: :timeout}} =
             Connection.next_userdata(client, subscription, 10)

    non_owner = Task.async(fn -> Connection.next_userdata(client, subscription, 10) end)
    assert {:error, %Error{reason: :invalid_subscription}} = Task.await(non_owner)

    assert {:error, %Error{reason: :invalid_subscription}} =
             Connection.next_userdata(client, make_ref(), 10)

    assert Connection.unsubscribe_userdata(client, subscription) == :ok
    assert Client.close(client) == :ok
  end

  test "delivers an indication directly to a waiting subscription caller" do
    server = start_server(userdata_fault: :indication_before_response)
    client = connect(server)
    assert {:ok, subscription} = Connection.subscribe_userdata(client, %{})
    assert {:ok, request} = UserData.request(:cpu, 1, <<>>)

    request_task =
      Task.async(fn ->
        Process.sleep(20)
        Connection.userdata(client, request)
      end)

    assert {:ok, %UserData{payload: %{data: "event1"}}} =
             Connection.next_userdata(client, subscription, 500)

    assert {:ok, %UserData{}} = Task.await(request_task)
    assert Connection.unsubscribe_userdata(client, subscription) == :ok
    assert Client.close(client) == :ok
  end

  test "wakes a subscription waiter when its session closes" do
    server = start_server()
    client = connect(server)
    parent = self()

    owner =
      spawn(fn ->
        {:ok, subscription} = Connection.subscribe_userdata(client, %{})
        send(parent, {:subscription_waiting, self(), subscription})
        result = Connection.next_userdata(client, subscription, 1_000)
        send(parent, {:subscription_result, self(), result})
      end)

    assert_receive {:subscription_waiting, ^owner, _subscription}, 500
    Process.sleep(20)
    assert Client.close(client) == :ok

    assert_receive {:subscription_result, ^owner,
                    {:error, %Error{reason: :connection_closed, operation: :next_userdata}}},
                   500
  end

  defp connect(server) do
    assert {:ok, client} =
             Client.connect({127, 0, 0, 1}, port: server.port, timeout: 500)

    client
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_queue(client, queued), do: await_info(client, &(&1.queued_requests == queued))
  defp await_state(client, state), do: await_info(client, &(&1.state == state))

  defp await_subscriptions(client, subscriptions),
    do: await_info(client, &(&1.subscriptions == subscriptions))

  defp await_info(client, predicate, attempts \\ 50)

  defp await_info(client, predicate, attempts) when attempts > 0 do
    info = Client.info(client)

    if predicate.(info) do
      info
    else
      Process.sleep(10)
      await_info(client, predicate, attempts - 1)
    end
  end

  defp await_info(client, _predicate, 0), do: Client.info(client)
end
