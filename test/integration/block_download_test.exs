defmodule S7.BlockDownloadIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Block, Error}
  alias S7.Protocol.{BlockDownload, PDU}
  alias S7.Test.{Fixture, MockPLC}

  test "requires both connection capability and exact per-call confirmation" do
    image = captured_image()
    server = start_server(notify_requests: true, expected_download_image: image.raw)
    assert {:ok, client} = connect(server)

    assert {:error, %Error{reason: :destructive_operations_disabled}} =
             S7.Blocks.download(client, image, confirm: :download_block)

    refute_receive {:mock_plc_request, :download_start, _reference}, 30
    assert S7.close(client) == :ok

    enabled_server = start_server(notify_requests: true, expected_download_image: image.raw)
    assert {:ok, enabled} = connect(enabled_server, allow_destructive: true)

    assert {:error, %Error{reason: :destructive_confirmation_required}} =
             S7.Blocks.download(enabled, image)

    assert {:error, %Error{reason: :destructive_confirmation_required}} =
             S7.Blocks.download(enabled, image, confirm: :replace_block)

    refute_receive {:mock_plc_request, :download_start, _reference}, 30
    assert S7.close(enabled) == :ok
  end

  test "downloads, reassembles, and activates across negotiated PDU slices" do
    image = captured_image()

    server =
      start_server(
        expected_download_image: image.raw,
        expected_download_block: image.block,
        negotiated_pdu: 100,
        notify_requests: true
      )

    assert {:ok, client} = connect(server, allow_destructive: true, pdu_size: 100)

    assert S7.Blocks.download(client, image, confirm: :download_block) == :ok
    assert_receive {:mock_plc_downloaded, block, raw}, 500
    assert block == image.block
    assert raw == image.raw
    assert_receive {:mock_plc_block_activated, ^block, ^raw}, 500

    assert_receive {:mock_plc_request, :download_segment, _reference}, 500
    assert_receive {:mock_plc_request, :download_segment, _reference}, 500
    assert_receive {:mock_plc_request, :download_segment, _reference}, 500
    refute_receive {:mock_plc_request, :download_segment, _reference}, 30

    assert %{state: :ready, destructive_operations: true, exclusive_transaction: false} =
             S7.TestSupport.info!(client)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "supports explicit replacement and validated raw download" do
    image = captured_image()
    replace_server = start_server(expected_download_image: image.raw)
    assert {:ok, replace_client} = connect(replace_server, allow_destructive: true)

    assert S7.Blocks.replace(replace_client, image, confirm: :replace_block) == :ok
    assert S7.close(replace_client) == :ok

    raw_server = start_server(expected_download_image: image.raw)
    assert {:ok, raw_client} = connect(raw_server, allow_destructive: true)

    assert S7.Blocks.download_raw(
             raw_client,
             :db,
             1,
             image.raw,
             confirm: :download_block
           ) == :ok

    assert S7.close(raw_client) == :ok
  end

  test "deletes a block only through the destructive policy" do
    block = %Block{type: :db, number: 1}
    server = start_server(notify_requests: true)
    assert {:ok, client} = connect(server, allow_destructive: true)

    assert S7.Blocks.delete(client, block, confirm: :delete_block) == :ok
    assert_receive {:mock_plc_block_deleted, ^block}, 500
    assert_receive {:mock_plc_request, :delete_block, _reference}, 500
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(client) == :ok
  end

  test "keeps complete PLC rejections usable and reports activation state" do
    image = captured_image()

    start_server =
      start_server(expected_download_image: image.raw, download_fault: :start_rejected)

    assert {:ok, start_client} = connect(start_server, allow_destructive: true)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.Blocks.download(start_client, image, confirm: :download_block)

    assert S7.read(start_client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(start_client) == :ok

    end_server =
      start_server(expected_download_image: image.raw, download_fault: :download_end_rejected)

    assert {:ok, end_client} = connect(end_server, allow_destructive: true)

    assert {:error, %Error{reason: :block_download_rejected, code: 0xD241}} =
             S7.Blocks.download(end_client, image, confirm: :download_block)

    assert S7.read(end_client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(end_client) == :ok

    insert_server =
      start_server(expected_download_image: image.raw, download_fault: :insert_rejected)

    assert {:ok, insert_client} = connect(insert_server, allow_destructive: true)

    assert {:error,
            %Error{
              reason: :access_denied,
              details: %{outcome: :downloaded_not_activated, stage: :activate_block}
            }} = S7.Blocks.download(insert_client, image, confirm: :download_block)

    assert S7.read(insert_client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(insert_client) == :ok

    delete_server = start_server(download_fault: :delete_rejected)
    assert {:ok, delete_client} = connect(delete_server, allow_destructive: true)

    assert {:error, %Error{reason: :access_denied, details: %{outcome: :rejected}}} =
             S7.Blocks.delete(delete_client, :db, 1, confirm: :delete_block)

    assert S7.read(delete_client, "DB1.DBW0") == {:ok, 1234}
    assert S7.close(delete_client) == :ok
  end

  test "invalidates malformed, timed-out, and disconnected download transactions" do
    image = captured_image()

    for {fault, expected_reason} <- [
          {:malformed_start_response, :malformed_response},
          {:malformed_download_job, :malformed_response},
          {:wrong_download_identity, :malformed_response},
          {:malformed_download_end, :malformed_response},
          {:malformed_insert_response, :malformed_response},
          {:segment_silence, :timeout},
          {:segment_disconnect, :connection_closed}
        ] do
      server = start_server(expected_download_image: image.raw, download_fault: fault)
      assert {:ok, client} = connect(server, allow_destructive: true)
      step_timeout = if fault == :segment_silence, do: 30, else: 500

      assert {:error, %Error{reason: reason, details: %{outcome: :indeterminate}}} =
               S7.Blocks.download(client, image,
                 confirm: :download_block,
                 step_timeout: step_timeout
               )

      if fault == :segment_disconnect do
        assert reason in [:connection_closed, :remote_disconnect]
      else
        assert reason == expected_reason
      end

      assert %{state: :disconnected, exclusive_transaction: false} = S7.TestSupport.info!(client)
      assert S7.close(client) == :ok
    end
  end

  test "queues ordinary work and disconnects if the destructive owner dies" do
    image = captured_image()

    queued_server =
      start_server(
        expected_download_image: image.raw,
        download_response_delay: 100,
        notify_requests: true
      )

    assert {:ok, queued_client} = connect(queued_server, allow_destructive: true)

    download =
      Task.async(fn ->
        S7.Blocks.download(queued_client, image, confirm: :download_block)
      end)

    assert_receive {:mock_plc_request, :download_pull, _reference}, 500
    read = Task.async(fn -> S7.read(queued_client, "DB1.DBW0") end)
    assert %{exclusive_transaction: true, queued_requests: 1} = await_queue(queued_client)
    assert Task.await(download) == :ok
    assert Task.await(read) == {:ok, 1234}
    assert S7.close(queued_client) == :ok

    owner_server =
      start_server(
        expected_download_image: image.raw,
        download_response_delay: 100,
        notify_requests: true
      )

    assert {:ok, owner_client} = connect(owner_server, allow_destructive: true)

    owner =
      spawn(fn ->
        S7.Blocks.download(owner_client, image, confirm: :download_block)
      end)

    assert_receive {:mock_plc_request, :download_pull, _reference}, 500
    Process.exit(owner, :kill)

    assert %{state: :disconnected} = await_state(owner_client, :disconnected)
    assert S7.close(owner_client) == :ok
  end

  test "rejects malformed raw images before sending destructive traffic" do
    image = captured_image()
    server = start_server(notify_requests: true)
    assert {:ok, client} = connect(server, allow_destructive: true)
    malformed = :binary.replace(image.raw, <<0x70, 0x70>>, <<0, 0>>, [:global])

    assert {:error, %Error{reason: :malformed_block_image}} =
             S7.Blocks.download_raw(client, image.block, malformed, confirm: :download_block)

    refute_receive {:mock_plc_request, :download_start, _reference}, 30
    assert S7.close(client) == :ok
  end

  defp captured_image do
    assert {:ok, pdu, <<>>} = Fixture.read!("download/block_response.bin") |> PDU.decode()
    assert {:ok, %{data: raw}} = BlockDownload.decode_download_response(pdu, :test)
    assert {:ok, image} = Block.Image.decode(raw, %Block{type: :db, number: 1})
    image
  end

  defp connect(server, opts) do
    S7.connect(
      {127, 0, 0, 1},
      Keyword.merge([port: server.port, timeout: 1_000], opts)
    )
  end

  defp connect(server), do: connect(server, [])

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
