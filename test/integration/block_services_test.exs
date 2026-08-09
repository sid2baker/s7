defmodule S7.BlockServicesIntegrationTest do
  use ExUnit.Case, async: true

  alias S7.{Block, Error}
  alias S7.Test.MockPLC

  test "counts, lists, and inspects blocks through the public API" do
    server = start_server(block_fragment_entries: 1)
    assert {:ok, client} = connect(server)

    assert {:ok,
            %Block.Inventory{
              counts: %{ob: 1, fb: 1, fc: 0, db: 2, sdb: 8, sfc: 77, sfb: 15}
            }} = S7.Blocks.counts(client)

    assert {:ok,
            [
              %Block.Entry{block: %Block{type: :db, number: 1}, language: :db},
              %Block.Entry{block: %Block{type: :db, number: 2}, language: :db}
            ]} = S7.Blocks.list(client, :db)

    assert {:ok, sfc_entries} =
             S7.Blocks.list(client, :sfc, max_bytes: 1_024, max_fragments: 16)

    assert Enum.count(sfc_entries) == 10

    assert {:ok,
            %Block.Info{
              block: %Block{type: :db, number: 1},
              author: "SIMATIC",
              name: "CTU"
            }} = S7.Blocks.info(client, :db, 1)

    assert {:ok, %Block.Info{block: %Block{type: :db, number: 1}}} =
             S7.Blocks.info(client, %Block{type: :db, number: 1})

    assert %{state: :ready, in_flight_requests: 0} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "a PLC block lookup error retains its code and leaves the session usable" do
    server = start_server()
    assert {:ok, client} = connect(server)

    assert {:error,
            %Error{
              layer: :s7,
              operation: :block_info,
              reason: :userdata_error,
              code: 0xD209
            }} = S7.Blocks.info(client, :db, 2)

    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert %{state: :ready} = S7.TestSupport.info!(client)
    assert S7.close(client) == :ok
  end

  test "validates block requests before submitting them" do
    server = start_server()
    assert {:ok, client} = connect(server)

    assert {:error, %Error{layer: :client, reason: :invalid_block}} =
             S7.Blocks.list(client, :invalid)

    assert {:error, %Error{layer: :client, reason: :invalid_option}} =
             S7.Blocks.list(client, :db, max_fragments: 0)

    assert {:error, %Error{layer: :client, reason: :invalid_options}} =
             S7.Blocks.list(client, :db, :invalid)

    assert {:error, %Error{layer: :client, reason: :invalid_block}} =
             S7.Blocks.info(client, :db, -1)

    assert %{state: :ready, in_flight_requests: 0, queued_requests: 0} =
             S7.TestSupport.info!(client)

    assert S7.close(client) == :ok
  end

  test "fragment limits and malformed block payloads invalidate the session safely" do
    fragment_server = start_server(block_fragment_entries: 1)
    assert {:ok, fragment_client} = connect(fragment_server)

    assert {:error, %Error{operation: :list_blocks, reason: :too_many_userdata_fragments}} =
             S7.Blocks.list(fragment_client, :db, max_fragments: 1)

    assert %{state: :disconnected} = S7.TestSupport.info!(fragment_client)
    assert S7.close(fragment_client) == :ok

    malformed_server = start_server(block_fault: :malformed_geometry)
    assert {:ok, malformed_client} = connect(malformed_server)

    assert {:error, %Error{operation: :list_blocks, reason: :malformed_response}} =
             S7.Blocks.list(malformed_client, :db)

    assert Process.alive?(malformed_client)
    assert %{state: :disconnected} = S7.TestSupport.info!(malformed_client)
    assert S7.close(malformed_client) == :ok
  end

  defp connect(server) do
    S7.connect({127, 0, 0, 1}, port: server.port, timeout: 1_000)
  end

  defp start_server(opts \\ []) do
    {:ok, server} = MockPLC.start_link(opts)
    on_exit(fn -> MockPLC.stop(server) end)
    server
  end
end
