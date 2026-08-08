defmodule S7.Client do
  @moduledoc """
  Public API for a single classic S7comm connection.

  One request is outstanding at a time in v0.1. The returned client is a PID
  whose process owns the TCP socket.
  """

  alias S7.{Address, Connection, Data, Error, Result}

  @opaque t :: pid()
  @type address :: String.t() | Address.t()
  @type multi_reply ::
          {:ok, [Result.t()]}
          | {:error, Error.t()}
          | {:error, Error.t(), [Result.t()]}

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
  Reads multiple addresses, automatically splitting them against the
  negotiated PDU size. Results preserve input order and PLC item errors.
  """
  @spec read_multi(t(), [address()]) :: multi_reply()
  def read_multi(client, addresses), do: read_many(client, addresses, false, :read_multi)

  @doc """
  Reads multiple addresses without typed payload conversion.
  """
  @spec read_multi_raw(t(), [address()]) :: multi_reply()
  def read_multi_raw(client, addresses), do: read_many(client, addresses, true, :read_multi)

  @doc """
  Encodes and writes one scalar value.
  """
  @spec write(t(), address(), Data.value()) :: :ok | {:error, Error.t()}
  def write(client, address, value) do
    with {:ok, address} <- normalize_address(address),
         {:ok, encoded} <- Data.encode(address.data_type, value, address.count) do
      call(fn -> Connection.write(client, address, encoded) end, :write)
    end
  end

  @doc """
  Writes already encoded bytes after validating their exact size against the
  address type and count.
  """
  @spec write_raw(t(), address(), binary()) :: :ok | {:error, Error.t()}
  def write_raw(client, address, value) do
    with {:ok, address} <- normalize_address(address),
         {:ok, encoded} <- Data.validate_raw(address.data_type, value, address.count) do
      call(fn -> Connection.write(client, address, encoded) end, :write)
    end
  end

  @doc """
  Writes multiple typed values, automatically splitting them against the
  negotiated PDU size. A transport failure returns completed, indeterminate,
  and not-attempted item states in a three-element error tuple.
  """
  @spec write_multi(t(), [{address(), Data.value()}]) :: multi_reply()
  def write_multi(client, items), do: write_many(client, items, :typed)

  @doc """
  Writes multiple already encoded payloads after exact size validation.
  """
  @spec write_multi_raw(t(), [{address(), binary()}]) :: multi_reply()
  def write_multi_raw(client, items), do: write_many(client, items, :raw)

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
  defp normalize_address(%Address{} = address), do: Address.validate(address)

  defp normalize_address(address) do
    {:error, Error.new(:address, :parse, :invalid_address, details: %{address: address})}
  end

  defp read_many(client, addresses, raw?, operation) do
    with {:ok, addresses} <- normalize_addresses(addresses, operation) do
      call(fn -> Connection.read_multi(client, addresses, raw?) end, operation)
    end
  end

  defp write_many(client, items, mode) do
    with {:ok, items} <- normalize_write_items(items, mode) do
      call(fn -> Connection.write_multi(client, items) end, :write_multi)
    end
  end

  defp normalize_addresses(addresses, _operation) when is_list(addresses) and addresses != [] do
    addresses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {address, index}, {:ok, normalized} ->
      case normalize_address(address) do
        {:ok, address} -> {:cont, {:ok, [address | normalized]}}
        {:error, %Error{} = error} -> {:halt, {:error, add_item_context(error, index)}}
      end
    end)
    |> reverse_normalized()
  end

  defp normalize_addresses(addresses, operation) do
    {:error, Error.new(:client, operation, :invalid_items, details: %{items: addresses})}
  end

  defp normalize_write_items(items, mode) when is_list(items) and items != [] do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {{address, value}, index}, {:ok, normalized} ->
        with {:ok, address} <- normalize_address(address),
             {:ok, encoded} <- encode_write_value(address, value, mode) do
          {:cont, {:ok, [{address, encoded} | normalized]}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, add_item_context(error, index)}}
        end

      {item, index}, _accumulator ->
        error =
          Error.new(:client, :write_multi, :invalid_item, details: %{index: index, item: item})

        {:halt, {:error, error}}
    end)
    |> reverse_normalized()
  end

  defp normalize_write_items(items, _mode) do
    {:error, Error.new(:client, :write_multi, :invalid_items, details: %{items: items})}
  end

  defp encode_write_value(address, value, :typed),
    do: Data.encode(address.data_type, value, address.count)

  defp encode_write_value(address, value, :raw),
    do: Data.validate_raw(address.data_type, value, address.count)

  defp reverse_normalized({:ok, normalized}), do: {:ok, Enum.reverse(normalized)}
  defp reverse_normalized({:error, error}), do: {:error, error}

  defp add_item_context(error, index),
    do: %{error | details: Map.put(error.details, :index, index)}

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
