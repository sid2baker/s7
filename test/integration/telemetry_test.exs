defmodule S7.TelemetryIntegrationTest do
  use ExUnit.Case, async: false

  alias S7.{Client, Telemetry}
  alias S7.Test.MockPLC

  setup do
    handler_id = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        Telemetry.events(),
        &__MODULE__.handle_event/4,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  @doc false
  def handle_event(event, measurements, metadata, owner) do
    send(owner, {:s7_telemetry, event, measurements, metadata})
  end

  test "emits correlated connection and request events without process data" do
    server = start_server()
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port)
    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.close(client) == :ok

    assert_receive {:s7_telemetry, [:s7, :connection, :connected], connected,
                    %{connection: ^client, reconnected: false}}

    assert %{pdu_size: 240, max_jobs: 1} = connected

    assert_receive {:s7_telemetry, [:s7, :request, :queued], queued,
                    %{connection: ^client, operation: :read, request_id: request_id}}

    assert queued.queue_depth == 1

    assert_receive {:s7_telemetry, [:s7, :request, :start], started,
                    %{
                      connection: ^client,
                      operation: :read,
                      request_id: ^request_id,
                      reference: reference
                    } = start_metadata}

    assert is_integer(reference)
    assert started.request_size > 0
    assert started.queue_duration >= 0

    assert_receive {:s7_telemetry, [:s7, :request, :stop], stopped,
                    %{
                      connection: ^client,
                      request_id: ^request_id,
                      reference: ^reference,
                      outcome: :ok,
                      item_error_count: 0
                    } = stop_metadata}

    assert stopped.duration >= 0
    assert stopped.response_size > 0

    assert_receive {:s7_telemetry, [:s7, :connection, :disconnected], _measurements,
                    %{connection: ^client, error_reason: :connection_closed}}

    for metadata <- [start_metadata, stop_metadata] do
      assert Map.keys(metadata) -- Telemetry.excluded_metadata() == Map.keys(metadata)
    end
  end

  test "reports bounded reconnect scheduling" do
    port = reserve_port()

    assert {:ok, client} =
             Client.start_link(
               host: {127, 0, 0, 1},
               port: port,
               reconnect: true,
               reconnect_min_delay: 50,
               reconnect_max_delay: 50,
               reconnect_max_attempts: 1,
               reconnect_jitter: 0,
               timeout: 100
             )

    assert_receive {:s7_telemetry, [:s7, :connection, :reconnect_scheduled], measurements,
                    %{connection: ^client, port: ^port}}

    assert measurements.attempt == 1
    assert System.convert_time_unit(measurements.delay, :native, :millisecond) == 50
    assert Client.close(client) == :ok
  end

  test "publishes a stable event and metadata-exclusion contract" do
    assert [:s7, :request, :start] in Telemetry.events()
    assert [:s7, :request, :stop] in Telemetry.events()
    assert :address in Telemetry.excluded_metadata()
    assert :value in Telemetry.excluded_metadata()
    assert :payload in Telemetry.excluded_metadata()
  end

  test "never publishes session credentials in request telemetry" do
    secret = "PRIVATE"
    server = start_server(session_password: secret)
    assert {:ok, client} = Client.connect({127, 0, 0, 1}, port: server.port)
    assert Client.authenticate(client, secret) == :ok

    for event <- [
          [:s7, :request, :queued],
          [:s7, :request, :start],
          [:s7, :request, :stop]
        ] do
      assert_receive {:s7_telemetry, ^event, measurements,
                      %{connection: ^client, operation: :authenticate} = metadata}

      refute inspect({measurements, metadata}) =~ secret
    end

    assert Client.close(client) == :ok
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp reserve_port do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_address, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    port
  end
end
