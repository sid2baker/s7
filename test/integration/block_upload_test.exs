defmodule S7.BlockUploadIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Block, Error}
  alias S7.Protocol.PDU
  alias S7.Test.{Fixture, MockPLC}

  test "uploads, assembles, parses, and preserves a multi-fragment block image" do
    raw = captured_image()
    server = start_server(upload_image: raw, upload_block: block(), upload_chunk_size: 37)
    assert {:ok, client} = connect(server)

    assert {:ok, %Block.Image{block: %Block{type: :sdb, number: 0}, raw: ^raw}} =
             S7.Blocks.upload(client, block(), max_fragments: 8)

    assert S7.Blocks.upload_raw(client, :sdb, 0, max_fragments: 8) == {:ok, raw}

    assert %{state: :ready, exclusive_transaction: false, in_flight_requests: 0} =
             S7.TestSupport.info!(client)

    assert S7.close(client) == :ok
  end

  test "reserves the connection and bounds callers waiting behind an upload" do
    server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        upload_response_delay: 100,
        notify_requests: true
      )

    assert {:ok, client} = connect(server, queue_limit: 1)
    upload = Task.async(fn -> S7.Blocks.upload(client, block()) end)
    assert_receive {:mock_plc_request, :upload_segment, _reference}, 500

    read = Task.async(fn -> S7.read(client, "DB1.DBW0") end)
    assert %{exclusive_transaction: true, queued_requests: 1} = await_queue(client, 1)
    refute_receive {:mock_plc_request, :read, _reference}, 30

    assert {:error, %Error{reason: :queue_full, details: %{limit: 1}}} =
             S7.read(client, "DB1.DBW0")

    assert {:ok, %Block.Image{}} = Task.await(upload)
    assert Task.await(read) == {:ok, 1234}
    assert_receive {:mock_plc_request, :upload_end, _reference}, 500
    assert_receive {:mock_plc_request, :read, _reference}, 500
    assert S7.close(client) == :ok
  end

  test "keeps the session usable after an initial PLC rejection" do
    server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        upload_fault: :start_rejected
      )

    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.Blocks.upload(client, block())

    assert %{state: :ready, exclusive_transaction: false} = S7.TestSupport.info!(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "ends the remote upload cleanly when local byte or fragment bounds are reached" do
    size_server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        notify_requests: true
      )

    assert {:ok, size_client} = connect(size_server)

    assert {:error,
            %Error{
              reason: :block_upload_too_large,
              details: %{size: 216, limit: 100}
            }} = S7.Blocks.upload(size_client, block(), max_bytes: 100)

    assert_receive {:mock_plc_request, :upload_start, _reference}, 500
    assert_receive {:mock_plc_request, :upload_end, _reference}, 500
    refute_receive {:mock_plc_request, :upload_segment, _reference}, 30
    assert S7.read(size_client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(size_client) == :ok

    fragment_server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        upload_chunk_size: 50,
        notify_requests: true
      )

    assert {:ok, fragment_client} = connect(fragment_server)

    assert {:error, %Error{reason: :too_many_upload_fragments, details: %{limit: 1}}} =
             S7.Blocks.upload(fragment_client, block(), max_fragments: 1)

    assert_receive {:mock_plc_request, :upload_segment, _reference}, 500
    assert_receive {:mock_plc_request, :upload_end, _reference}, 500
    assert S7.read(fragment_client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(fragment_client) == :ok
  end

  test "invalidates ambiguous malformed and disconnected upload sessions" do
    malformed_server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        upload_fault: :malformed_segment
      )

    assert {:ok, malformed_client} = connect(malformed_server)

    assert {:error, %Error{reason: :malformed_response}} =
             S7.Blocks.upload(malformed_client, block())

    assert %{state: :disconnected, exclusive_transaction: false} =
             S7.TestSupport.info!(malformed_client)

    assert S7.close(malformed_client) == :ok

    disconnected_server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        upload_fault: :segment_disconnect
      )

    assert {:ok, disconnected_client} = connect(disconnected_server)

    assert {:error, %Error{reason: reason}} = S7.Blocks.upload(disconnected_client, block())
    assert reason in [:connection_closed, :remote_disconnect]

    assert %{state: :disconnected, exclusive_transaction: false} =
             S7.TestSupport.info!(disconnected_client)

    assert S7.close(disconnected_client) == :ok
  end

  test "invalidates malformed start/end envelopes and bounded step timeouts" do
    for fault <- [:malformed_start, :malformed_end, :segment_silence] do
      server =
        start_server(
          upload_image: captured_image(),
          upload_block: block(),
          upload_fault: fault
        )

      assert {:ok, client} = connect(server)

      step_timeout = if fault == :segment_silence, do: 20, else: 200

      assert {:error, %Error{reason: reason}} =
               S7.Blocks.upload(client, block(), step_timeout: step_timeout)

      expected_reason = if fault == :segment_silence, do: :timeout, else: :malformed_response
      assert reason == expected_reason
      assert %{state: :disconnected, exclusive_transaction: false} = S7.TestSupport.info!(client)
      assert S7.close(client) == :ok
    end
  end

  test "finishes the wire transaction before reporting an invalid block image" do
    raw = replace(captured_image(), 0, <<0, 0>>)
    server = start_server(upload_image: raw, upload_block: block())
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :malformed_block_image}} =
             S7.Blocks.upload(client, block())

    assert %{state: :ready, exclusive_transaction: false} = S7.TestSupport.info!(client)
    assert S7.Blocks.upload_raw(client, block()) == {:ok, raw}
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "disconnects if the upload owner dies mid-transaction" do
    server =
      start_server(
        upload_image: captured_image(),
        upload_block: block(),
        upload_response_delay: 100,
        notify_requests: true
      )

    assert {:ok, client} = connect(server)
    caller = spawn(fn -> S7.Blocks.upload(client, block()) end)
    assert_receive {:mock_plc_request, :upload_segment, _reference}, 500
    Process.exit(caller, :kill)

    assert %{state: :disconnected, exclusive_transaction: false} =
             await_state(client, :disconnected)

    assert S7.close(client) == :ok
  end

  test "rejects invalid blocks and options before reserving the connection" do
    server = start_server()
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :invalid_block}} = S7.Blocks.upload(client, :invalid, 1)

    assert {:error, %Error{reason: :invalid_option}} =
             S7.Blocks.upload(client, block(), max_bytes: 0)

    assert %{state: :ready, exclusive_transaction: false, queued_requests: 0} =
             S7.TestSupport.info!(client)

    assert S7.close(client) == :ok
  end

  defp captured_image do
    assert {:ok, %{data: <<216::unsigned-big-16, 0x00FB::unsigned-big-16, raw::binary>>}, <<>>} =
             Fixture.read!("upload/segment_response.bin") |> PDU.decode()

    raw
  end

  defp block, do: %Block{type: :sdb, number: 0}

  defp replace(binary, offset, replacement) do
    size = byte_size(replacement)
    <<prefix::binary-size(^offset), _old::binary-size(^size), suffix::binary>> = binary
    prefix <> replacement <> suffix
  end

  defp connect(server, opts \\ []) do
    S7.connect(
      {127, 0, 0, 1},
      Keyword.merge([port: server.port, timeout: 1_000], opts)
    )
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end

  defp await_queue(client, expected), do: await_info(client, &(&1.queued_requests == expected))
  defp await_state(client, expected), do: await_info(client, &(&1.state == expected))

  defp await_info(client, predicate, attempts \\ 100)

  defp await_info(client, predicate, attempts) when attempts > 0 do
    info = S7.TestSupport.info!(client)

    if predicate.(info) do
      info
    else
      Process.sleep(5)
      await_info(client, predicate, attempts - 1)
    end
  end

  defp await_info(client, _predicate, 0), do: S7.TestSupport.info!(client)
end
