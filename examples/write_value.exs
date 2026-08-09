required_env = fn name ->
  case System.fetch_env(name) do
    {:ok, value} when value != "" ->
      value

    _ ->
      IO.puts(:stderr, "#{name} is required; no default write target is provided")
      System.halt(64)
  end
end

parse_value = fn value ->
  case String.downcase(value) do
    "true" ->
      true

    "false" ->
      false

    value ->
      case Integer.parse(value) do
        {integer, ""} ->
          integer

        _ ->
          IO.puts(:stderr, "S7_WRITE_VALUE must be an integer, true, or false")
          System.halt(64)
      end
  end
end

host = System.get_env("S7_HOST", "127.0.0.1")
port = System.get_env("S7_PORT", "102") |> String.to_integer()
rack = System.get_env("S7_RACK", "0") |> String.to_integer()
slot = System.get_env("S7_SLOT", "2") |> String.to_integer()
timeout = System.get_env("S7_TIMEOUT", "5000") |> String.to_integer()
address = required_env.("S7_WRITE_ADDRESS")
value = required_env.("S7_WRITE_VALUE") |> parse_value.()

result =
  case S7.connect(host, port: port, rack: rack, slot: slot, timeout: timeout) do
    {:ok, client} ->
      try do
        with {:ok, previous} <- S7.read(client, address),
             :ok <- S7.write(client, address, value),
             {:ok, current} <- S7.read(client, address) do
          {:ok, previous, current}
        end
      after
        _ = S7.close(client)
      end

    {:error, error} ->
      {:error, error}
  end

case result do
  {:ok, previous, current} ->
    IO.inspect(previous, label: "previous #{address}")
    IO.inspect(current, label: "current #{address}")

  {:error, %S7.Error{} = error} ->
    IO.puts(:stderr, Exception.message(error))
    System.halt(1)
end
