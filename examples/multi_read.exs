host = System.get_env("S7_HOST", "127.0.0.1")
port = System.get_env("S7_PORT", "102") |> String.to_integer()
rack = System.get_env("S7_RACK", "0") |> String.to_integer()
slot = System.get_env("S7_SLOT", "2") |> String.to_integer()
timeout = System.get_env("S7_TIMEOUT", "5000") |> String.to_integer()

addresses =
  "S7_ADDRESSES"
  |> System.get_env("DB1.DBW0,MW10,IW0")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

result =
  case S7.connect(host, port: port, rack: rack, slot: slot, timeout: timeout) do
    {:ok, client} ->
      try do
        S7.read_many(client, addresses)
      after
        _ = S7.close(client)
      end

    {:error, error} ->
      {:error, error}
  end

print_results = fn results ->
  addresses
  |> Enum.zip(results)
  |> Enum.each(fn
    {address, %S7.Result{status: :ok, value: value}} ->
      IO.inspect(value, label: address)

    {address, %S7.Result{status: status, error: %S7.Error{} = error}} ->
      IO.puts(:stderr, "#{address}: #{status} (#{Exception.message(error)})")

    {address, %S7.Result{status: status}} ->
      IO.puts(:stderr, "#{address}: #{status}")
  end)
end

case result do
  {:ok, results} ->
    print_results.(results)

    if Enum.any?(results, &(&1.status != :ok)) do
      System.halt(1)
    end

  {:error, %S7.Error{} = error, results} ->
    print_results.(results)
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)

  {:error, %S7.Error{} = error} ->
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)
end
