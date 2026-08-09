defmodule S7 do
  @moduledoc """
  An OTP-native classic S7comm client over ISO-on-TCP.

  `S7` owns the core connection lifecycle and memory-access API. Advanced
  classic services are grouped under `S7.PLC`, `S7.Blocks`, `S7.Cyclic`,
  `S7.Alarm`, `S7.Programmer`, and `S7.Session`.

  A connected client is a PID or registered name for the `S7.Connection`
  process that owns the TCP socket. Protocol and transport modules remain pure
  binary codecs and can be used independently for diagnostics and testing.
  """

  alias S7.{API, Connection, Data, Error, Result}

  @opaque t :: GenServer.server()
  @type address :: String.t() | S7.Address.t()
  @type multi_reply ::
          {:ok, [Result.t()]}
          | {:error, Error.t()}
          | {:error, Error.t(), [Result.t()]}

  @doc """
  Starts a linked, supervision-ready client from keyword options.

  `:host` is required. With `reconnect: true`, an unavailable endpoint leaves
  the process alive in `:reconnecting`; otherwise startup fails.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: start_link_options(opts), else: invalid_start_options(opts)
  end

  def start_link(opts), do: invalid_start_options(opts)

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    id = Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__))

    %{
      id: id,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc """
  Connects to a PLC and completes COTP and Setup Communication negotiation.

  Options include `:rack` (default `0`), `:slot` (default `2`), `:port`
  (default `102`), `:timeout` in milliseconds (default `5000`),
  `:connection_type`, explicit `:src_tsap`/`:dst_tsap`, `:tpdu_size`, the
  requested S7 `:pdu_size`, requested `:max_jobs`, local `:queue_limit`, and
  `:allow_destructive` (default `false`).
  """
  @spec connect(:inet.hostname() | :inet.ip_address(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def connect(host, opts \\ []) do
    case Connection.start(host, opts) do
      {:ok, connection} -> finish_connect(connection)
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.new(:client, :connect, :start_failed, code: reason)}
    end
  end

  @doc """
  Reads and decodes one value or fixed-count range.
  """
  @spec read(t(), address()) :: {:ok, Data.value()} | {:error, Error.t()}
  def read(client, address) do
    with {:ok, address} <- API.address(address) do
      API.call(fn -> Connection.read(client, address, false) end, :read)
    end
  end

  @doc """
  Reads one value or fixed-count range without converting its payload bytes.
  """
  @spec read_raw(t(), address()) :: {:ok, binary()} | {:error, Error.t()}
  def read_raw(client, address) do
    with {:ok, address} <- API.address(address) do
      API.call(fn -> Connection.read(client, address, true) end, :read)
    end
  end

  @doc """
  Reads multiple addresses, splitting them against the negotiated PDU size.

  Results preserve input order and PLC item errors.
  """
  @spec read_many(t(), [address()]) :: multi_reply()
  def read_many(client, addresses), do: read_many(client, addresses, false)

  @doc """
  Reads multiple addresses without typed payload conversion.
  """
  @spec read_many_raw(t(), [address()]) :: multi_reply()
  def read_many_raw(client, addresses), do: read_many(client, addresses, true)

  @doc """
  Encodes and writes one value or fixed-count range.
  """
  @spec write(t(), address(), Data.value()) :: :ok | {:error, Error.t()}
  def write(client, address, value) do
    with {:ok, address} <- API.address(address),
         {:ok, encoded} <- Data.encode(address.data_type, value, address.count) do
      API.call(fn -> Connection.write(client, address, encoded) end, :write)
    end
  end

  @doc """
  Writes already encoded bytes after validating their exact size.
  """
  @spec write_raw(t(), address(), binary()) :: :ok | {:error, Error.t()}
  def write_raw(client, address, value) do
    with {:ok, address} <- API.address(address),
         {:ok, encoded} <- Data.validate_raw(address.data_type, value, address.count) do
      API.call(fn -> Connection.write(client, address, encoded) end, :write)
    end
  end

  @doc """
  Writes multiple typed values, splitting them against the negotiated PDU size.

  A transport failure preserves completed, indeterminate, and not-attempted
  item states in the three-element error tuple.
  """
  @spec write_many(t(), [{address(), Data.value()}]) :: multi_reply()
  def write_many(client, items), do: write_many(client, items, :typed)

  @doc """
  Writes multiple already encoded payloads after exact size validation.
  """
  @spec write_many_raw(t(), [{address(), binary()}]) :: multi_reply()
  def write_many_raw(client, items), do: write_many(client, items, :raw)

  @doc """
  Returns negotiated connection information and current runtime counts.
  """
  @spec info(t()) :: {:ok, map()} | {:error, Error.t()}
  def info(client) do
    case API.call(fn -> Connection.info(client) end, :info) do
      %{} = info -> {:ok, info}
      {:error, %Error{}} = error -> error
    end
  end

  @doc """
  Starts a fresh session on a disconnected long-lived client.

  Work from a failed session is never replayed.
  """
  @spec reconnect(t()) :: :ok | {:error, Error.t()}
  def reconnect(client), do: API.call(fn -> Connection.connect(client) end, :connect)

  @doc """
  Closes the TCP connection and stops its owner process.

  The default `mode: :immediate` fails accepted work. `mode: :drain` rejects
  new calls and waits up to `:timeout` milliseconds for accepted work.
  """
  @spec close(t(), keyword()) :: :ok | {:error, Error.t()}
  def close(client, opts \\ []) do
    case API.call(fn -> Connection.close(client, opts) end, :close) do
      {:error, %Error{reason: :connection_closed}} -> :ok
      result -> result
    end
  end

  defp start_link_options(opts) do
    with {:ok, host} <- fetch_start_host(opts) do
      connection_opts = Keyword.drop(opts, [:host, :id])

      case Connection.start_link(host, connection_opts) do
        {:ok, connection} -> finish_start_link(connection, connection_opts)
        {:error, %Error{} = error} -> {:error, error}
        {:error, reason} -> {:error, Error.new(:client, :connect, :start_failed, code: reason)}
      end
    end
  end

  defp invalid_start_options(opts),
    do: {:error, Error.new(:client, :connect, :invalid_options, details: %{options: opts})}

  defp fetch_start_host(opts) do
    case Keyword.fetch(opts, :host) do
      {:ok, host} -> {:ok, host}
      :error -> {:error, Error.new(:client, :connect, :missing_host)}
    end
  end

  defp finish_connect(connection) do
    case API.call(fn -> Connection.connect(connection) end, :connect) do
      :ok ->
        {:ok, connection}

      {:error, %Error{} = error} ->
        stop_connection(connection)
        {:error, error}
    end
  end

  defp finish_start_link(connection, opts) do
    case API.call(fn -> Connection.connect(connection) end, :connect) do
      :ok ->
        {:ok, connection}

      {:error, %Error{} = error} ->
        if Keyword.get(opts, :reconnect, false) and Process.alive?(connection) do
          {:ok, connection}
        else
          stop_connection(connection)
          {:error, error}
        end
    end
  end

  defp read_many(client, addresses, raw?) do
    with {:ok, addresses} <- API.addresses(addresses, :read_many) do
      API.call(fn -> Connection.read_many(client, addresses, raw?) end, :read_many)
    end
  end

  defp write_many(client, items, mode) do
    with {:ok, items} <- API.write_items(items, mode, :write_many) do
      API.call(fn -> Connection.write_many(client, items) end, :write_many)
    end
  end

  defp stop_connection(connection) do
    if Process.alive?(connection), do: Connection.close(connection), else: :ok
  end
end
