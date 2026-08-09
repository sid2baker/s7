host = System.get_env("S7_HOST", "127.0.0.1")
port = System.get_env("S7_PORT", "102") |> String.to_integer()
rack = System.get_env("S7_RACK", "0") |> String.to_integer()
slot = System.get_env("S7_SLOT", "2") |> String.to_integer()
timeout = System.get_env("S7_TIMEOUT", "5000") |> String.to_integer()
address = System.get_env("S7_ADDRESS", "DB1.DBW0")

result =
  case S7.connect(host, port: port, rack: rack, slot: slot, timeout: timeout) do
    {:ok, client} ->
      try do
        S7.read(client, address)
      after
        _ = S7.close(client)
      end

    {:error, error} ->
      {:error, error}
  end

case result do
  {:ok, value} ->
    IO.inspect(value, label: address)

  {:error, %S7.Error{} = error} ->
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)
end
