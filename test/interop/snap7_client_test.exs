defmodule S7.Snap7ClientInteropTest do
  use ExUnit.Case

  @moduletag :external

  alias S7.{
    Address,
    Alarm,
    Block,
    Error,
    PLC,
    Result,
    SZL
  }

  alias S7.Protocol.{BlockDownload, PDU}
  alias S7.Test.Fixture

  setup do
    host = System.fetch_env!("S7_TEST_HOST")
    port = System.fetch_env!("S7_TEST_PORT") |> String.to_integer()

    {:ok, client} =
      S7.connect(host,
        port: port,
        timeout: 2_000,
        max_jobs: 4,
        allow_destructive: true
      )

    on_exit(fn -> S7.close(client) end)
    {:ok, client: client}
  end

  test "negotiates and reads and writes every v0.1 area and scalar type", %{client: client} do
    assert %{state: :ready, pdu_size: 480, max_jobs: 4} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
    assert S7.read(client, "I0.7") == {:ok, true}

    concurrent_reads =
      for _index <- 1..4 do
        Task.async(fn -> S7.read(client, "DB1.DBW0") end)
      end

    assert Enum.map(concurrent_reads, &Task.await/1) == List.duplicate({:ok, 1234}, 4)

    values = [
      {"DB1.DBX20.3", true},
      {"DB1.DBB2", 0xA5},
      {"DB1.DBW4", 0xBEEF},
      {"DB1.DBD8", 0x12345678},
      {"M10.0", true},
      {"MB12", 0x5A},
      {"MW14", 0xCAFE},
      {"MD16", 0x89ABCDEF},
      {"Q0.0", true},
      {"QB2", 0xAA},
      {"QW4", 0x55AA},
      {"QD8", 0x10203040}
    ]

    for {address, value} <- values do
      assert S7.write(client, address, value) == :ok
      assert S7.read(client, address) == {:ok, value}
    end

    typed_values = [
      {%Address{area: :db, db_number: 1, byte_offset: 24, data_type: :int}, -12_345},
      {%Address{area: :db, db_number: 1, byte_offset: 28, data_type: :dint}, -123_456_789},
      {%Address{area: :db, db_number: 1, byte_offset: 32, data_type: :real}, 12.5}
    ]

    for {address, value} <- typed_values do
      assert S7.write(client, address, value) == :ok
      assert S7.read(client, address) == {:ok, value}
    end

    words = %Address{area: :db, db_number: 1, byte_offset: 100, data_type: :word, count: 3}
    assert S7.write(client, words, [1, 0x1234, 0xFFFF]) == :ok
    assert S7.read(client, words) == {:ok, [1, 0x1234, 0xFFFF]}

    bytes = %Address{area: :db, db_number: 1, byte_offset: 120, data_type: :byte, count: 5}
    assert S7.write_raw(client, bytes, <<1, 2, 3, 4, 5>>) == :ok
    assert S7.read_raw(client, bytes) == {:ok, <<1, 2, 3, 4, 5>>}

    writes =
      for offset <- 300..349 do
        address = %Address{area: :db, db_number: 1, byte_offset: offset, data_type: :byte}
        {address, rem(offset, 256)}
      end

    assert {:ok, write_results} = S7.write_multi(client, writes)
    assert Enum.all?(write_results, &match?(%Result{status: :ok}, &1))

    addresses = Enum.map(writes, &elem(&1, 0))
    assert {:ok, read_results} = S7.read_multi(client, addresses)
    assert Enum.map(read_results, & &1.value) == Enum.map(writes, &elem(&1, 1))
  end

  test "reads raw and typed classic SZL metadata", %{client: client} do
    assert {:ok, %SZL{id: 0x0011, record_length: 28, record_count: count}} =
             S7.read_szl(client, 0x0011)

    assert count > 0
    assert {:ok, ids} = S7.list_szl(client)
    assert 0x0011 in ids
    assert 0x001C in ids

    assert {:ok, %PLC.OrderCode{code: code}} = S7.order_code(client)
    assert code != ""
    assert {:ok, %PLC.CPUInfo{module_type_name: module_type}} = S7.cpu_info(client)
    assert is_binary(module_type)
    assert {:ok, %PLC.CPInfo{max_pdu_length: max_pdu}} = S7.cp_info(client)
    assert max_pdu > 0
    assert {:ok, %PLC.Status{state: state}} = S7.plc_status(client)
    assert state in [:run, :stop, :unknown]
  end

  test "reads the classic block directory and DB metadata", %{client: client} do
    assert {:ok, %Block.Inventory{counts: %{db: 1}}} = S7.block_counts(client)

    assert {:ok,
            [
              %Block.Entry{
                block: %Block{type: :db, number: 1},
                language: :db,
                flags: 0x22
              }
            ]} = S7.list_blocks(client, :db)

    assert {:ok,
            %Block.Info{
              block: %Block{type: :db, number: 1},
              language: :db,
              linked?: true,
              mc7_size: 512,
              load_memory_size: 604
            }} = S7.block_info(client, :db, 1)
  end

  test "sets the classic clock and changes session authorization", %{client: client} do
    assert S7.set_clock(client, ~N[2024-08-09 12:34:56.000]) == :ok

    assert %{authenticated: false} = S7.info(client)
    assert S7.authenticate(client, "TESTONLY") == :ok
    assert %{authenticated: true} = S7.info(client)
    assert S7.logout(client) == :ok
    assert %{authenticated: false} = S7.info(client)
  end

  test "reports the pinned server's explicit upload protection without losing the session", %{
    client: client
  } do
    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             S7.upload_block(client, :db, 1)

    assert %{state: :ready, exclusive_transaction: false} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
  end

  test "bounds the pinned server's silent programmer-service drop", %{client: client} do
    assert {:error, %Error{reason: :transaction_timeout}} =
             S7.variable_status(client, ["MB0"], timeout: 200, step_timeout: 200)

    assert %{state: :disconnected, exclusive_transaction: false, subscriptions: 0} =
             S7.info(client)
  end

  test "bounds the pinned server's silent cyclic-service drop", %{client: client} do
    assert {:error, %Error{reason: :transaction_timeout}} =
             S7.subscribe_cyclic(client, ["MB0"], timeout: 200, step_timeout: 200)

    assert %{state: :disconnected, exclusive_transaction: false, subscriptions: 0} =
             S7.info(client)
  end

  test "rejects the pinned server's malformed alarm-subscription response", %{client: client} do
    assert {:error, %Error{reason: :malformed_response}} =
             S7.subscribe_alarms(client, :alarm_8, timeout: 200, step_timeout: 200)

    assert %{state: :disconnected, exclusive_transaction: false, subscriptions: 0} =
             S7.info(client)
  end

  test "decodes the pinned server's alarm-query rejection", %{client: client} do
    assert {:error, %Error{reason: :userdata_error, code: 0xD402}} =
             S7.query_alarms(client, :alarm_8)

    assert %{state: :ready, exclusive_transaction: false, subscriptions: 0} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
  end

  test "decodes the pinned server's alarm acknowledgment rejection", %{client: client} do
    acknowledgement = %Alarm.Acknowledgement{
      event_id: 0xAF,
      ack_state_going: 0xFE,
      ack_state_coming: 0xFE
    }

    assert {:error,
            %Error{
              reason: :userdata_error,
              code: 0xD402,
              details: %{outcome: :rejected}
            }} =
             S7.acknowledge_alarm(client, acknowledgement,
               timeout: 200,
               step_timeout: 200
             )

    assert %{state: :ready, exclusive_transaction: false, subscriptions: 0} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
  end

  test "decodes download protection and emits a PI block-control request", %{client: client} do
    image = captured_download_image()

    assert {:error,
            %Error{
              reason: :access_denied,
              code: 0xD241,
              details: %{outcome: :rejected, stage: :request_download}
            }} = S7.download_block(client, image, confirm: :download_block)

    assert S7.delete_block(client, :db, 65_000, confirm: :delete_block) == :ok
    assert %{state: :ready, exclusive_transaction: false} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
  end

  test "controls the disposable server CPU and runs bounded maintenance services", %{
    client: client
  } do
    assert S7.stop_cpu(client, confirm: :stop_cpu) == :ok
    assert {:ok, %PLC.Status{state: :stop}} = S7.plc_status(client)

    assert S7.warm_start_cpu(client, confirm: :warm_start_cpu) == :ok
    assert {:ok, %PLC.Status{state: :run}} = S7.plc_status(client)

    assert S7.stop_cpu(client, confirm: :stop_cpu) == :ok
    assert S7.cold_start_cpu(client, confirm: :cold_start_cpu) == :ok
    assert {:ok, %PLC.Status{state: :run}} = S7.plc_status(client)

    assert S7.stop_cpu(client, confirm: :stop_cpu) == :ok
    assert S7.copy_ram_to_rom(client, confirm: :copy_ram_to_rom) == :ok
    assert S7.compress_memory(client, confirm: :compress_memory) == :ok

    assert %{state: :ready, exclusive_transaction: false} = S7.info(client)
    assert S7.read(client, "DB1.DBW0") == {:ok, 1234}
  end

  defp captured_download_image do
    assert {:ok, pdu, <<>>} = Fixture.read!("download/block_response.bin") |> PDU.decode()
    assert {:ok, %{data: raw}} = BlockDownload.decode_download_response(pdu, :interop)
    assert {:ok, image} = Block.Image.decode(raw, %Block{type: :db, number: 1})
    image
  end
end
