defmodule S7.SoakTest do
  use ExUnit.Case, async: false

  @moduletag :soak

  alias S7.Test.MockPLC

  test "sustains bounded concurrent traffic without retaining request state" do
    iterations = soak_iterations()

    {:ok, server} =
      MockPLC.start_link(
        fragment_tcp: false,
        negotiated_jobs: 8,
        negotiated_pdu: 480
      )

    on_exit(fn -> MockPLC.stop(server) end)

    assert {:ok, client} =
             S7.connect({127, 0, 0, 1},
               port: server.port,
               max_jobs: 8,
               queue_limit: 64,
               timeout: 2_000
             )

    :erlang.garbage_collect(client)
    baseline_memory = process_memory(client)

    results =
      1..iterations
      |> Task.async_stream(&operation(client, &1),
        max_concurrency: 32,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.frequencies()

    assert results == %{{:ok, :ok} => iterations}

    assert %{in_flight_requests: 0, queued_requests: 0, state: :ready} =
             S7.TestSupport.info!(client)

    :erlang.garbage_collect(client)
    assert process_memory(client) <= baseline_memory + 1_000_000
    assert {:message_queue_len, 0} = Process.info(client, :message_queue_len)
    assert S7.close(client, mode: :drain) == :ok
  end

  defp operation(client, iteration) when rem(iteration, 2) == 0 do
    case S7.read(client, "DB1.DBW0") do
      {:ok, 1234} -> :ok
      result -> result
    end
  end

  defp operation(client, iteration) do
    S7.write(client, "MB40", rem(iteration, 0x100))
  end

  defp soak_iterations do
    case Integer.parse(System.get_env("S7_SOAK_ITERATIONS", "5000")) do
      {iterations, ""} when iterations > 0 -> iterations
      _invalid -> raise "S7_SOAK_ITERATIONS must be a positive integer"
    end
  end

  defp process_memory(process) do
    {:memory, bytes} = Process.info(process, :memory)
    bytes
  end
end
