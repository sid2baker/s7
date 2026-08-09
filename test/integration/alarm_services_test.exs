defmodule S7.AlarmServicesIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Alarm, Error}

  alias S7.Alarm.Acknowledgement.Result, as: AcknowledgementResult
  alias S7.Alarm.Event.Object, as: AlarmObject
  alias S7.Alarm.Query.Record, as: QueryRecord
  alias S7.Test.MockPLC

  test "subscribes, preserves ordered duplicates, queries, acknowledges, and tears down" do
    server =
      start_server(
        notify_requests: true,
        alarm_event_ids: [0xAF, 0xAF, 0x2F],
        alarm_query_event_ids: [0xAF, 0x2F]
      )

    assert {:ok, client} = connect(server)

    assert {:ok,
            %Alarm.Subscription{
              connection: ^client,
              alarm_type: :alarm_8,
              subscription_key: "HmiRtm  "
            } = subscription} =
             S7.subscribe_alarms(client, :alarm_8, queue_limit: 4)

    assert_receive {:mock_plc_request, :alarm_subscribe, _reference}, 500

    assert %{state: :ready, subscriptions: 1, exclusive_transaction: false} =
             S7.info(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}

    assert {:ok,
            %Alarm.Event{
              kind: :alarm_8,
              objects: [
                %AlarmObject{
                  event_id: 0xAF,
                  associated_values: [%{data: <<0x04, 0xD2>>}]
                } = first_object
              ]
            }} = S7.next_alarm(client, subscription, 500)

    assert {:ok, %Alarm.Event{objects: [%AlarmObject{event_id: 0xAF}]}} =
             S7.next_alarm(client, subscription, 500)

    assert {:ok, %Alarm.Event{objects: [%AlarmObject{event_id: 0x2F}]}} =
             S7.next_alarm(client, subscription, 500)

    assert {:ok,
            %Alarm.Query{
              selector: {:alarm_type, :alarm_8},
              records: [
                %QueryRecord{event_id: 0xAF, alarm_type: :alarm_8},
                %QueryRecord{event_id: 0x2F, alarm_type: :alarm_8}
              ]
            }} = S7.query_alarms(client, :alarm_8)

    assert {:ok,
            %Alarm.Query{
              selector: {:event_id, 0xAF},
              records: [%QueryRecord{event_id: 0xAF} | _]
            }} = S7.query_alarm(client, 0xAF)

    assert S7.acknowledge_alarm(client, first_object) == :ok
    assert_receive {:mock_plc_request, :alarm_acknowledge, _reference}, 500

    assert S7.unsubscribe_alarms(client, subscription) == :ok
    assert_receive {:mock_plc_request, :alarm_unsubscribe, _reference}, 500

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             S7.info(client)

    assert {:error, %Error{reason: :invalid_subscription, operation: :next_alarm}} =
             S7.next_alarm(client, subscription, 10)

    assert S7.close(client) == :ok
  end

  test "supports ALARM_S subscriptions and empty alarm queries" do
    server = start_server(alarm_event_ids: [0x0102_0304], alarm_query_empty: true)
    assert {:ok, client} = connect(server)

    assert {:ok, %Alarm.Subscription{alarm_type: :alarm_s} = subscription} =
             S7.subscribe_alarms(client, :alarm_s)

    assert {:ok,
            %Alarm.Event{
              kind: :alarm_s,
              subfunction: 0x12,
              objects: [%AlarmObject{event_id: 0x0102_0304}]
            }} = S7.next_alarm(client, subscription, 500)

    assert {:ok,
            %Alarm.Query{
              selector: {:alarm_type, :alarm_s},
              return_code: 0x0A,
              records: []
            }} = S7.query_alarms(client, :alarm_s)

    assert S7.unsubscribe_alarms(client, subscription) == :ok
    assert S7.close(client) == :ok
  end

  test "keeps a complete subscription rejection session-safe" do
    server = start_server(alarm_fault: :setup_rejected, alarm_push_count: 0)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.subscribe_alarms(client, :alarm_8)

    assert %{state: :ready, subscriptions: 0, exclusive_transaction: false} =
             S7.info(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "invalidates ambiguous subscription outcomes and removes provisional queues" do
    for {fault, expected} <- [
          {:setup_silence, :transaction_timeout},
          {:malformed_setup, :malformed_response}
        ] do
      server = start_server(alarm_fault: fault, alarm_push_count: 0)
      assert {:ok, client} = connect(server)

      assert {:error, %Error{reason: ^expected}} =
               S7.subscribe_alarms(client, :alarm_8,
                 timeout: 100,
                 step_timeout: 500
               )

      assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert S7.close(client) == :ok
    end
  end

  test "bounds unmatched and malformed indications without crashing" do
    for {fault, expected} <- [
          {:wrong_alarm_subfunction, :timeout},
          {:malformed_indication, :malformed_response},
          {:invalid_alarm_timestamp, :malformed_response}
        ] do
      server =
        start_server(
          alarm_fault: fault,
          alarm_event_ids: [0xAF],
          alarm_push_delay: 100
        )

      assert {:ok, client} = connect(server)
      assert {:ok, subscription} = S7.subscribe_alarms(client, :alarm_8)

      assert {:error, %Error{reason: ^expected}} =
               S7.next_alarm(client, subscription, 250)

      assert S7.unsubscribe_alarms(client, subscription) == :ok
      assert %{state: :ready, subscriptions: 0} = S7.info(client)
      assert S7.close(client) == :ok
    end
  end

  test "reports bounded queue overflow and still releases the remote subscription" do
    server =
      start_server(
        alarm_event_ids: [0xAF, 0xAF, 0x2F],
        alarm_push_delay: 100
      )

    assert {:ok, client} = connect(server)
    assert {:ok, subscription} = S7.subscribe_alarms(client, :alarm_8, queue_limit: 1)

    Process.sleep(150)

    assert {:error, %Error{reason: :subscription_overflow, details: %{limit: 1}}} =
             S7.next_alarm(client, subscription, 100)

    assert S7.unsubscribe_alarms(client, subscription) == :ok
    assert %{state: :ready, subscriptions: 0} = S7.info(client)
    assert S7.close(client) == :ok
  end

  test "invalidates rejected, missing, and malformed unsubscribe outcomes" do
    for {fault, expected} <- [
          {:unsubscribe_rejected, :access_denied},
          {:unsubscribe_silence, :transaction_timeout},
          {:malformed_unsubscribe, :malformed_response}
        ] do
      server = start_server(alarm_fault: fault, alarm_push_count: 0)
      assert {:ok, client} = connect(server)
      assert {:ok, subscription} = S7.subscribe_alarms(client, :alarm_8)

      assert {:error, %Error{reason: ^expected}} =
               S7.unsubscribe_alarms(client, subscription,
                 timeout: 100,
                 step_timeout: 500
               )

      assert %{state: :disconnected, subscriptions: 0, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert S7.close(client) == :ok
    end
  end

  test "returns per-item acknowledgment errors without invalidating the session" do
    server = start_server(alarm_fault: :ack_item_rejected, alarm_push_count: 0)
    assert {:ok, client} = connect(server)

    acknowledgements = [acknowledgement(0xAF), acknowledgement(0x2F)]

    assert {:ok,
            [
              %AcknowledgementResult{
                acknowledgement: %Alarm.Acknowledgement{event_id: 0xAF},
                status: :error,
                error: %Error{reason: :access_denied}
              },
              %AcknowledgementResult{
                acknowledgement: %Alarm.Acknowledgement{event_id: 0x2F},
                status: :ok
              }
            ]} = S7.acknowledge_alarms(client, acknowledgements)

    assert %{state: :ready, exclusive_transaction: false} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}

    oversized = Enum.map(1..30, &acknowledgement/1)

    assert {:error, %Error{reason: :pdu_too_large, details: %{outcome: :not_attempted}}} =
             S7.acknowledge_alarms(client, oversized)

    assert %{state: :ready, exclusive_transaction: false} = S7.info(client)
    assert S7.close(client) == :ok
  end

  test "classifies complete and ambiguous acknowledgment failures" do
    rejected_server = start_server(alarm_fault: :ack_rejected, alarm_push_count: 0)
    assert {:ok, rejected_client} = connect(rejected_server)

    assert {:error,
            %Error{
              reason: :access_denied,
              operation: :acknowledge_alarm,
              details: %{outcome: :rejected}
            }} = S7.acknowledge_alarm(rejected_client, acknowledgement(0xAF))

    assert %{state: :ready, exclusive_transaction: false} = S7.info(rejected_client)
    assert S7.close(rejected_client) == :ok

    for {fault, expected} <- [
          {:ack_silence, :transaction_timeout},
          {:malformed_ack, :malformed_response}
        ] do
      server = start_server(alarm_fault: fault, alarm_push_count: 0)
      assert {:ok, client} = connect(server)

      assert {:error, %Error{reason: ^expected, details: %{outcome: :indeterminate}}} =
               S7.acknowledge_alarm(client, acknowledgement(0xAF),
                 timeout: 100,
                 step_timeout: 500
               )

      assert %{state: :disconnected, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert S7.close(client) == :ok
    end
  end

  test "closes the session when an alarm subscription owner dies" do
    server = start_server(alarm_push_count: 0)
    assert {:ok, client} = connect(server)
    parent = self()

    owner =
      spawn(fn ->
        result = S7.subscribe_alarms(client, :alarm_8)
        send(parent, {:alarm_owner, self(), result})
        Process.sleep(:infinity)
      end)

    assert_receive {:alarm_owner, ^owner, {:ok, %Alarm.Subscription{}}}, 500
    assert %{subscriptions: 1} = S7.info(client)
    Process.exit(owner, :kill)

    assert %{state: :disconnected, subscriptions: 0} = await_state(client, :disconnected)
    assert S7.close(client) == :ok
  end

  test "validates alarm families, selectors, options, handles, and ownership locally" do
    server = start_server(notify_requests: true, alarm_push_count: 0)
    assert {:ok, client} = connect(server)

    for operation <- [
          fn -> S7.subscribe_alarms(client, :unknown) end,
          fn -> S7.subscribe_alarms(client, :alarm_8, queue_limit: 0) end,
          fn -> S7.subscribe_alarms(client, :alarm_8, subscription_key: "short") end,
          fn -> S7.subscribe_alarms(client, :alarm_8, unknown: true) end,
          fn -> S7.query_alarms(client, :scan) end
        ] do
      assert {:error, %Error{}} = operation.()
    end

    assert {:error, %Error{operation: :query_alarm}} = S7.query_alarm(client, -1)

    assert {:error,
            %Error{
              operation: :acknowledge_alarm,
              details: %{outcome: :not_attempted}
            }} = S7.acknowledge_alarm(client, :invalid)

    assert {:error,
            %Error{
              operation: :acknowledge_alarms,
              details: %{outcome: :not_attempted}
            }} = S7.acknowledge_alarms(client, [])

    refute_receive {:mock_plc_request, :alarm_subscribe, _reference}, 30

    assert {:ok, subscription} = S7.subscribe_alarms(client, :alarm_8)

    non_owner = Task.async(fn -> S7.next_alarm(client, subscription, 10) end)
    assert {:error, %Error{reason: :invalid_subscription}} = Task.await(non_owner)

    assert {:error, %Error{reason: :invalid_alarm_subscription}} =
             S7.unsubscribe_alarms(self(), subscription)

    assert S7.unsubscribe_alarms(client, subscription) == :ok
    assert S7.close(client) == :ok
  end

  defp acknowledgement(event_id) do
    %Alarm.Acknowledgement{
      event_id: event_id,
      ack_state_going: 1,
      ack_state_coming: 1
    }
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
  defp await_state(client, _expected, 0), do: S7.info(client)

  defp await_state(client, expected, attempts) do
    case S7.info(client) do
      %{state: ^expected} = info ->
        info

      _info ->
        Process.sleep(5)
        await_state(client, expected, attempts - 1)
    end
  end
end
