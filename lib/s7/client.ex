defmodule S7.Client do
  @moduledoc """
  Public API for a single classic S7comm connection.

  One request is outstanding at a time in v0.1. The returned client is a PID
  whose process owns the TCP socket.
  """

  alias S7.{Address, Connection, Data, Error}

  @opaque t :: pid()
  @type address :: String.t() | Address.t()

  @doc """
  Connects to a PLC and completes COTP and Setup Communication negotiation.

  Options include `:rack` (default `0`), `:slot` (default `2`), `:port`
  (default `102`), `:timeout` in milliseconds (default `5000`),
  `:connection_type`, explicit `:src_tsap`/`:dst_tsap`, `:tpdu_size`, and the
  requested S7 `:pdu_size`.
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
  Reads and decodes one scalar value.
  """
  @spec read(t(), address()) :: {:ok, Data.value()} | {:error, Error.t()}
  def read(client, address) do
    with {:ok, address} <- normalize_address(address) do
      call(fn -> Connection.read(client, address, false) end, :read)
    end
  end

  @doc """
  Reads one scalar value without converting its payload bytes.
  """
  @spec read_raw(t(), address()) :: {:ok, binary()} | {:error, Error.t()}
  def read_raw(client, address) do
    with {:ok, address} <- normalize_address(address) do
      call(fn -> Connection.read(client, address, true) end, :read)
    end
  end

  @doc """
  Encodes and writes one scalar value.
  """
  @spec write(t(), address(), Data.value()) :: :ok | {:error, Error.t()}
  def write(client, address, value) do
    with {:ok, address} <- normalize_address(address),
         {:ok, encoded} <- Data.encode(address.data_type, value) do
      call(fn -> Connection.write(client, address, encoded) end, :write)
    end
  end

  @doc """
  Returns negotiated connection information.
  """
  @spec info(t()) :: map() | {:error, Error.t()}
  def info(client), do: call(fn -> Connection.info(client) end, :info)

  @doc """
  Closes the TCP connection and stops its owner process.
  """
  @spec close(t()) :: :ok | {:error, Error.t()}
  def close(client) do
    case call(fn -> Connection.close(client) end, :close) do
      {:error, %Error{reason: :connection_closed}} -> :ok
      result -> result
    end
  end

  defp finish_connect(connection) do
    case call(fn -> Connection.connect(connection) end, :connect) do
      :ok ->
        {:ok, connection}

      {:error, %Error{} = error} ->
        stop_connection(connection)
        {:error, error}
    end
  end

  defp normalize_address(address) when is_binary(address), do: Address.parse(address)
  defp normalize_address(%Address{} = address), do: Address.validate_scalar(address)

  defp normalize_address(address) do
    {:error, Error.new(:address, :parse, :invalid_address, details: %{address: address})}
  end

  defp call(function, operation) do
    function.()
  catch
    :exit, {:noproc, _details} ->
      {:error, Error.new(:client, operation, :connection_closed)}

    :exit, {:normal, _details} ->
      {:error, Error.new(:client, operation, :connection_closed)}

    :exit, reason ->
      {:error, Error.new(:client, operation, :connection_process_exit, code: reason)}
  end

  defp stop_connection(connection) do
    if Process.alive?(connection) do
      Connection.close(connection)
    else
      :ok
    end
  end
end
