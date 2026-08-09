defmodule S7.PLCControlIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.Error
  alias S7.Test.MockPLC

  @actions [
    {:stop_cpu, :stop_cpu},
    {:warm_start_cpu, :warm_start_cpu},
    {:cold_start_cpu, :cold_start_cpu},
    {:copy_ram_to_rom, :copy_ram_to_rom},
    {:compress_memory, :compress_memory}
  ]

  test "requires both the connection capability and exact action confirmation" do
    server = start_server(notify_requests: true)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :destructive_operations_disabled}} =
             S7.stop_cpu(client, confirm: :stop_cpu)

    refute_receive {:mock_plc_request, :stop_cpu, _reference}, 30
    assert S7.close(client) == :ok

    enabled_server = start_server(notify_requests: true)
    assert {:ok, enabled} = connect(enabled_server, allow_destructive: true)

    assert {:error, %Error{reason: :destructive_confirmation_required}} =
             S7.stop_cpu(enabled)

    assert {:error,
            %Error{
              reason: :destructive_confirmation_required,
              details: %{expected: :stop_cpu, received: :warm_start_cpu}
            }} = S7.stop_cpu(enabled, confirm: :warm_start_cpu)

    refute_receive {:mock_plc_request, :stop_cpu, _reference}, 30
    assert S7.close(enabled) == :ok
  end

  test "executes every bounded CPU control action and releases exclusivity" do
    server = start_server(notify_requests: true)
    assert {:ok, client} = connect(server, allow_destructive: true)

    for {function, action} <- @actions do
      assert apply(S7, function, [client, [confirm: action]]) == :ok
      assert_receive {:mock_plc_request, ^action, _reference}, 500
      assert_receive {:mock_plc_controlled, ^action}, 500
      assert %{state: :ready, exclusive_transaction: false} = S7.TestSupport.info!(client)
    end

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "keeps a complete PLC rejection usable and reports a rejected outcome" do
    server = start_server(control_fault: :rejected)
    assert {:ok, client} = connect(server, allow_destructive: true)

    assert {:error,
            %Error{
              reason: :access_denied,
              code: 0xD241,
              details: %{outcome: :rejected, stage: :copy_ram_to_rom}
            }} = S7.copy_ram_to_rom(client, confirm: :copy_ram_to_rom)

    assert %{state: :ready, exclusive_transaction: false} = S7.TestSupport.info!(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "invalidates malformed, timed-out, and disconnected control outcomes" do
    for {fault, expected_reason} <- [
          {:malformed_response, :malformed_response},
          {:silence, :timeout},
          {:disconnect, :connection_closed}
        ] do
      server = start_server(control_fault: fault)
      assert {:ok, client} = connect(server, allow_destructive: true)
      step_timeout = if fault == :silence, do: 20, else: 500

      assert {:error,
              %Error{reason: reason, details: %{outcome: :indeterminate, stage: :stop_cpu}}} =
               S7.stop_cpu(client, confirm: :stop_cpu, step_timeout: step_timeout)

      if fault == :disconnect do
        assert reason in [:connection_closed, :remote_disconnect]
      else
        assert reason == expected_reason
      end

      assert %{state: :disconnected, exclusive_transaction: false} =
               await_state(client, :disconnected)

      assert S7.close(client) == :ok
    end
  end

  test "queues ordinary work behind a long control action" do
    server = start_server(control_response_delay: 100, notify_requests: true)
    assert {:ok, client} = connect(server, allow_destructive: true)

    control =
      Task.async(fn ->
        S7.compress_memory(client, confirm: :compress_memory)
      end)

    assert_receive {:mock_plc_request, :compress_memory, _reference}, 500
    read = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    assert %{exclusive_transaction: true, queued_requests: 1} = await_queue(client)

    assert Task.await(control) == :ok
    assert Task.await(read) == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  defp connect(server, opts \\ []) do
    S7.connect(
      {127, 0, 0, 1},
      Keyword.merge([port: server.port, timeout: 1_000], opts)
    )
  end

  defp start_server(opts) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_queue(client, attempts \\ 50)
  defp await_queue(client, 0), do: S7.TestSupport.info!(client)

  defp await_queue(client, attempts) do
    case S7.TestSupport.info!(client) do
      %{queued_requests: 1} = info ->
        info

      _info ->
        Process.sleep(5)
        await_queue(client, attempts - 1)
    end
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
