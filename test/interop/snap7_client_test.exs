defmodule S7.Snap7ClientInteropTest do
  use ExUnit.Case

  @moduletag :external

  alias S7.{Address, Client, Result}

  setup do
    host = System.fetch_env!("S7_TEST_HOST")
    port = System.fetch_env!("S7_TEST_PORT") |> String.to_integer()
    {:ok, client} = Client.connect(host, port: port, timeout: 2_000, max_jobs: 4)
    on_exit(fn -> Client.close(client) end)
    {:ok, client: client}
  end

  test "negotiates and reads and writes every v0.1 area and scalar type", %{client: client} do
    assert %{state: :ready, pdu_size: 480, max_jobs: 4} = Client.info(client)
    assert Client.read(client, "DB1.DBW0") == {:ok, 1234}
    assert Client.read(client, "I0.7") == {:ok, true}

    concurrent_reads =
      for _index <- 1..4 do
        Task.async(fn -> Client.read(client, "DB1.DBW0") end)
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
      assert Client.write(client, address, value) == :ok
      assert Client.read(client, address) == {:ok, value}
    end

    typed_values = [
      {%Address{area: :db, db_number: 1, byte_offset: 24, data_type: :int}, -12_345},
      {%Address{area: :db, db_number: 1, byte_offset: 28, data_type: :dint}, -123_456_789},
      {%Address{area: :db, db_number: 1, byte_offset: 32, data_type: :real}, 12.5}
    ]

    for {address, value} <- typed_values do
      assert Client.write(client, address, value) == :ok
      assert Client.read(client, address) == {:ok, value}
    end

    words = %Address{area: :db, db_number: 1, byte_offset: 100, data_type: :word, count: 3}
    assert Client.write(client, words, [1, 0x1234, 0xFFFF]) == :ok
    assert Client.read(client, words) == {:ok, [1, 0x1234, 0xFFFF]}

    bytes = %Address{area: :db, db_number: 1, byte_offset: 120, data_type: :byte, count: 5}
    assert Client.write_raw(client, bytes, <<1, 2, 3, 4, 5>>) == :ok
    assert Client.read_raw(client, bytes) == {:ok, <<1, 2, 3, 4, 5>>}

    writes =
      for offset <- 300..349 do
        address = %Address{area: :db, db_number: 1, byte_offset: offset, data_type: :byte}
        {address, rem(offset, 256)}
      end

    assert {:ok, write_results} = Client.write_multi(client, writes)
    assert Enum.all?(write_results, &match?(%Result{status: :ok}, &1))

    addresses = Enum.map(writes, &elem(&1, 0))
    assert {:ok, read_results} = Client.read_multi(client, addresses)
    assert Enum.map(read_results, & &1.value) == Enum.map(writes, &elem(&1, 1))
  end
end
