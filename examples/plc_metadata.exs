host = System.get_env("S7_HOST", "127.0.0.1")
port = System.get_env("S7_PORT", "102") |> String.to_integer()
rack = System.get_env("S7_RACK", "0") |> String.to_integer()
slot = System.get_env("S7_SLOT", "2") |> String.to_integer()
timeout = System.get_env("S7_TIMEOUT", "5000") |> String.to_integer()

show = fn label, result ->
  case result do
    {:ok, value} ->
      IO.inspect(value, label: label)

    {:error, %S7.Error{} = error} ->
      IO.puts(:stderr, "#{label}: #{Exception.message(error)}")

    value ->
      IO.inspect(value, label: label)
  end
end

case S7.connect(host, port: port, rack: rack, slot: slot, timeout: timeout) do
  {:ok, client} ->
    try do
      show.("connection", S7.info(client))
      show.("order code", S7.PLC.order_code(client))
      show.("CPU information", S7.PLC.cpu_info(client))
      show.("communication processor", S7.PLC.cp_info(client))
      show.("PLC status", S7.PLC.status(client))
      show.("PLC clock", S7.PLC.read_clock(client))
      show.("block counts", S7.Blocks.counts(client))
    after
      _ = S7.close(client)
    end

  {:error, %S7.Error{} = error} ->
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)
end
