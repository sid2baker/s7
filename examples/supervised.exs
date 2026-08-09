host = System.get_env("S7_HOST", "127.0.0.1")
port = System.get_env("S7_PORT", "102") |> String.to_integer()
rack = System.get_env("S7_RACK", "0") |> String.to_integer()
slot = System.get_env("S7_SLOT", "2") |> String.to_integer()
timeout = System.get_env("S7_TIMEOUT", "5000") |> String.to_integer()
address = System.get_env("S7_ADDRESS", "DB1.DBW0")
name = S7.Examples.PLC

children = [
  {S7, host: host, port: port, rack: rack, slot: slot, timeout: timeout, name: name}
]

case Supervisor.start_link(children, strategy: :one_for_one) do
  {:ok, supervisor} ->
    try do
      case S7.info(name) do
        {:ok, info} -> IO.inspect(info, label: "connection")
        {:error, error} -> raise error
      end

      case S7.read(name, address) do
        {:ok, value} ->
          IO.inspect(value, label: address)

        {:error, %S7.Error{} = error} ->
          IO.puts(:stderr, Exception.message(error))
          System.halt(1)
      end
    after
      Supervisor.stop(supervisor)
    end

  {:error, reason} ->
    IO.puts(:stderr, "could not start the S7 supervisor: #{inspect(reason)}")
    System.halt(1)
end
