defmodule S7.PLC do
  @moduledoc """
  PLC metadata, clock, status, and maintenance operations.

  Functions in this module operate on an established `S7` client. CPU control
  and maintenance operations retain the connection-level destructive opt-in
  and exact per-call confirmation requirements.
  """

  alias S7.{API, Connection, Destructive, Error, SZL}
  alias S7.Connection.DestructiveRequest
  alias S7.SZL.Metadata

  @doc """
  Reads one raw System Status List (SZL/SSL).

  Options are `:index` (default `0`), `:max_bytes`, and `:max_fragments`.
  """
  @spec read_szl(S7.t(), 0..0xFFFF, keyword()) :: {:ok, SZL.t()} | {:error, Error.t()}
  def read_szl(client, id, opts \\ [])

  def read_szl(client, id, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      {index, opts} = Keyword.pop(opts, :index, 0)
      read_szl_operation(client, id, index, opts, :read_szl)
    else
      invalid_options(:read_szl, opts)
    end
  end

  def read_szl(_client, _id, opts), do: invalid_options(:read_szl, opts)

  @doc """
  Lists the SZL IDs advertised by the connected CPU.
  """
  @spec list_szl(S7.t(), keyword()) :: {:ok, [0..0xFFFF]} | {:error, Error.t()}
  def list_szl(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0, 0, opts, :list_szl) do
      Metadata.available_ids(szl)
    end
  end

  @doc """
  Reads and decodes the module order code and three-part version.
  """
  @spec order_code(S7.t(), keyword()) :: {:ok, S7.PLC.OrderCode.t()} | {:error, Error.t()}
  def order_code(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x0011, 0, opts, :order_code) do
      Metadata.order_code(szl)
    end
  end

  @doc """
  Reads documented CPU component-identification strings.
  """
  @spec cpu_info(S7.t(), keyword()) :: {:ok, S7.PLC.CPUInfo.t()} | {:error, Error.t()}
  def cpu_info(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x001C, 0, opts, :cpu_info) do
      Metadata.cpu_info(szl)
    end
  end

  @doc """
  Reads communication-processor limits from SZL `0x0131`, index `1`.
  """
  @spec cp_info(S7.t(), keyword()) :: {:ok, S7.PLC.CPInfo.t()} | {:error, Error.t()}
  def cp_info(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x0131, 1, opts, :cp_info) do
      Metadata.cp_info(szl)
    end
  end

  @doc """
  Reads the PLC operating status without collapsing unknown status codes.
  """
  @spec status(S7.t(), keyword()) :: {:ok, S7.PLC.Status.t()} | {:error, Error.t()}
  def status(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x0424, 0, opts, :plc_status) do
      Metadata.plc_status(szl)
    end
  end

  @doc """
  Reads the PLC's timezone-free local civil time.
  """
  @spec read_clock(S7.t()) :: {:ok, S7.PLC.Clock.t()} | {:error, Error.t()}
  def read_clock(client), do: API.call(fn -> Connection.read_clock(client) end, :read_clock)

  @doc """
  Sets the PLC's timezone-free local civil time.

  This state-changing operation is never replayed after an ambiguous outcome.
  """
  @spec set_clock(S7.t(), NaiveDateTime.t()) :: :ok | {:error, Error.t()}
  def set_clock(client, datetime),
    do: API.call(fn -> Connection.set_clock(client, datetime) end, :set_clock)

  @doc """
  Stops CPU program execution.

  Requires `allow_destructive: true` and `confirm: :stop_cpu`.
  """
  @spec stop(S7.t(), keyword()) :: :ok | {:error, Error.t()}
  def stop(client, opts \\ []), do: control(client, :stop_cpu, opts)

  @doc """
  Performs a warm CPU start.

  Requires `allow_destructive: true` and `confirm: :warm_start_cpu`.
  """
  @spec warm_start(S7.t(), keyword()) :: :ok | {:error, Error.t()}
  def warm_start(client, opts \\ []), do: control(client, :warm_start_cpu, opts)

  @doc """
  Performs a cold CPU start.

  Requires `allow_destructive: true` and `confirm: :cold_start_cpu`.
  """
  @spec cold_start(S7.t(), keyword()) :: :ok | {:error, Error.t()}
  def cold_start(client, opts \\ []), do: control(client, :cold_start_cpu, opts)

  @doc """
  Copies PLC work memory from RAM to load memory.

  Requires `allow_destructive: true` and `confirm: :copy_ram_to_rom`.
  """
  @spec copy_ram_to_rom(S7.t(), keyword()) :: :ok | {:error, Error.t()}
  def copy_ram_to_rom(client, opts \\ []), do: control(client, :copy_ram_to_rom, opts)

  @doc """
  Requests PLC memory compression.

  Requires `allow_destructive: true` and `confirm: :compress_memory`.
  """
  @spec compress_memory(S7.t(), keyword()) :: :ok | {:error, Error.t()}
  def compress_memory(client, opts \\ []), do: control(client, :compress_memory, opts)

  defp read_szl_operation(client, id, index, opts, operation) do
    with {:ok, limits} <- SZL.validate_request(id, index, opts, operation) do
      API.call(fn -> Connection.read_szl(client, id, index, limits, operation) end, operation)
    end
  end

  defp control(client, action, opts) do
    with {:ok, limits} <- Destructive.validate_options(opts, action, action) do
      API.call(fn -> DestructiveRequest.control(client, action, limits, action) end, action)
    end
  end

  defp invalid_options(operation, opts),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}
end
