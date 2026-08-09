defmodule S7.Client do
  @moduledoc """
  Public API for a single classic S7comm connection.

  The returned client is a PID whose process owns the TCP socket. Requests are
  queued and correlated by PDU reference, with concurrency bounded by Setup
  Communication negotiation.
  """

  alias S7.{
    Address,
    Block,
    Connection,
    Data,
    Destructive,
    Error,
    PLC,
    Programmer,
    Result,
    SessionPassword,
    SZL
  }

  alias S7.Connection.{Alarm, BlockDownloader, BlockUploader, Cyclic, DestructiveRequest}
  alias S7.Connection.Programmer, as: ProgrammerRuntime
  alias S7.SZL.Metadata

  @opaque t :: GenServer.server()
  @type address :: String.t() | Address.t()
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
  `:connection_type`, explicit `:src_tsap`/`:dst_tsap`, `:tpdu_size`, and the
  requested S7 `:pdu_size`, requested `:max_jobs`, local `:queue_limit`, and
  `:allow_destructive` (default `false`). Destructive calls also require their
  operation-specific confirmation option.
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
  Reads one raw System Status List (SZL/SSL) and assembles bounded userdata
  fragments. Record bytes are preserved in the returned `S7.SZL` struct.

  Options are `:max_bytes` and `:max_fragments`.
  """
  @spec read_szl(t(), 0..0xFFFF) :: {:ok, SZL.t()} | {:error, Error.t()}
  def read_szl(client, id), do: read_szl_operation(client, id, 0, [], :read_szl)

  @spec read_szl(t(), 0..0xFFFF, 0..0xFFFF | keyword()) ::
          {:ok, SZL.t()} | {:error, Error.t()}
  def read_szl(client, id, opts) when is_list(opts),
    do: read_szl_operation(client, id, 0, opts, :read_szl)

  def read_szl(client, id, index), do: read_szl_operation(client, id, index, [], :read_szl)

  @spec read_szl(t(), 0..0xFFFF, 0..0xFFFF, keyword()) ::
          {:ok, SZL.t()} | {:error, Error.t()}
  def read_szl(client, id, index, opts),
    do: read_szl_operation(client, id, index, opts, :read_szl)

  @doc """
  Lists the SZL IDs advertised by the connected CPU.
  """
  @spec list_szl(t(), keyword()) :: {:ok, [0..0xFFFF]} | {:error, Error.t()}
  def list_szl(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0, 0, opts, :list_szl) do
      Metadata.available_ids(szl)
    end
  end

  @doc """
  Reads and decodes the module order code and three-part version.
  """
  @spec order_code(t(), keyword()) :: {:ok, PLC.OrderCode.t()} | {:error, Error.t()}
  def order_code(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x0011, 0, opts, :order_code) do
      Metadata.order_code(szl)
    end
  end

  @doc """
  Reads documented CPU component-identification strings.
  """
  @spec cpu_info(t(), keyword()) :: {:ok, PLC.CPUInfo.t()} | {:error, Error.t()}
  def cpu_info(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x001C, 0, opts, :cpu_info) do
      Metadata.cpu_info(szl)
    end
  end

  @doc """
  Reads communication-processor limits from SZL `0x0131`, index `1`.
  """
  @spec cp_info(t(), keyword()) :: {:ok, PLC.CPInfo.t()} | {:error, Error.t()}
  def cp_info(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x0131, 1, opts, :cp_info) do
      Metadata.cp_info(szl)
    end
  end

  @doc """
  Reads the PLC operating status without collapsing unknown raw status codes.
  """
  @spec plc_status(t(), keyword()) :: {:ok, PLC.Status.t()} | {:error, Error.t()}
  def plc_status(client, opts \\ []) do
    with {:ok, szl} <- read_szl_operation(client, 0x0424, 0, opts, :plc_status) do
      Metadata.plc_status(szl)
    end
  end

  @doc """
  Reads the PLC's timezone-free local civil time.

  Classic clock values contain no UTC offset. The returned `S7.PLC.Clock`
  retains the complete ten-byte timestamp and the unreliable century hint.
  """
  @spec read_clock(t()) :: {:ok, PLC.Clock.t()} | {:error, Error.t()}
  def read_clock(client), do: call(fn -> Connection.read_clock(client) end, :read_clock)

  @doc """
  Sets the PLC's timezone-free local civil time.

  This changes PLC state and is never retried automatically after an ambiguous
  timeout or disconnect.
  """
  @spec set_clock(t(), NaiveDateTime.t()) :: :ok | {:error, Error.t()}
  def set_clock(client, datetime) do
    call(fn -> Connection.set_clock(client, datetime) end, :set_clock)
  end

  @doc """
  Authenticates the current classic S7 session with its configured password.

  The exchange changes authorization only; it is neither encrypted nor peer
  authenticated. Passwords must contain one to eight printable ASCII bytes.
  They are redacted from inspection and telemetry, are not retained for
  reconnect, and cannot be securely zeroed by the BEAM's immutable binary
  representation.
  """
  @spec authenticate(t(), binary()) :: :ok | {:error, Error.t()}
  def authenticate(client, password) do
    with {:ok, password} <- SessionPassword.new(password) do
      call(fn -> Connection.authenticate(client, password) end, :authenticate)
    end
  end

  @doc """
  Clears authorization established for the current classic S7 session.
  """
  @spec logout(t()) :: :ok | {:error, Error.t()}
  def logout(client), do: call(fn -> Connection.logout(client) end, :logout)

  @doc """
  Samples one capture-backed classic programmer diagnostic job.

  `service` may be a documented service atom or its raw subfunction byte.
  `setup_parameters` and `setup_data` are preserved service records derived
  from a known packet exchange. Only read-only programmer subfunctions are
  accepted. Options are `:timeout` and `:step_timeout`.

  The job is set up, enabled once, deleted, and released before this function
  returns. The indication remains raw in `S7.Programmer.Event` because record
  layouts vary across CPU families.
  """
  @spec programmer_diagnostic_raw(
          t(),
          Programmer.Event.service() | byte(),
          binary(),
          binary(),
          keyword()
        ) :: {:ok, Programmer.Event.t()} | {:error, Error.t()}
  def programmer_diagnostic_raw(client, service, setup_parameters, setup_data, opts \\ []) do
    operation = :programmer_diagnostic

    with {:ok, limits} <- ProgrammerRuntime.validate_options(opts, operation) do
      call(
        fn ->
          ProgrammerRuntime.diagnostic(
            client,
            service,
            setup_parameters,
            setup_data,
            limits,
            operation
          )
        end,
        operation
      )
    end
  end

  @doc """
  Samples addresses through the classic STEP 7 variable-status service.

  This is distinct from Read Var: the PLC creates a temporary programmer job,
  emits one indication, and the client then deletes that job. Returned items
  retain the raw transport record and include a typed value when its PLC return
  code is successful. Options are `:timeout` and `:step_timeout`.
  """
  @spec variable_status(t(), [address()], keyword()) ::
          {:ok, Programmer.VariableStatus.t()} | {:error, Error.t()}
  def variable_status(client, addresses, opts \\ []) do
    with {:ok, addresses} <- normalize_addresses(addresses, :variable_status),
         {:ok, limits} <- ProgrammerRuntime.validate_options(opts, :variable_status) do
      call(
        fn -> ProgrammerRuntime.variable_status(client, addresses, limits) end,
        :variable_status
      )
    end
  end

  @doc """
  Starts a fixed-interval classic cyclic subscription for typed addresses.

  Options are `:interval` in exact milliseconds (default `1000`),
  `:queue_limit`, `:timeout`, and `:step_timeout`. The returned handle belongs
  to the calling process and current S7 session. Its `initial` field contains
  the optional snapshot returned by the PLC.
  """
  @spec subscribe_cyclic(t(), [address()], keyword()) ::
          {:ok, S7.Cyclic.Subscription.t()} | {:error, Error.t()}
  def subscribe_cyclic(client, addresses, opts \\ []) do
    with {:ok, addresses} <- normalize_addresses(addresses, :subscribe_cyclic),
         {:ok, options} <- Cyclic.validate_subscribe_options(opts, :subscribe_cyclic) do
      call(fn -> Cyclic.subscribe(client, addresses, options) end, :subscribe_cyclic)
    end
  end

  @doc """
  Starts a raw cyclic or change-driven subscription.

  `mode` is `:cyclic` or `:change_driven`. Each item must be one complete
  S7ANY (`0x10`) or DBREAD (`0xB0`) variable specification beginning with
  `0x12`. Incoming records are preserved in `S7.Cyclic.Event.Item` without
  CPU-specific interpretation.
  """
  @spec subscribe_cyclic_raw(
          t(),
          S7.Cyclic.Subscription.mode(),
          [binary()],
          keyword()
        ) :: {:ok, S7.Cyclic.Subscription.t()} | {:error, Error.t()}
  def subscribe_cyclic_raw(client, mode, item_specs, opts \\ []) do
    with {:ok, options} <- Cyclic.validate_subscribe_options(opts, :subscribe_cyclic_raw) do
      call(
        fn -> Cyclic.subscribe_raw(client, mode, item_specs, options) end,
        :subscribe_cyclic_raw
      )
    end
  end

  @doc """
  Pulls the next bounded update from a cyclic subscription.

  The caller must be the process that created the handle. A timeout does not
  cancel the remote subscription and the handle remains usable.
  """
  @spec next_cyclic(t(), S7.Cyclic.Subscription.t(), pos_integer()) ::
          {:ok, S7.Cyclic.Event.t()} | {:error, Error.t()}
  def next_cyclic(client, subscription, timeout \\ 5_000) do
    call(fn -> Cyclic.next(client, subscription, timeout) end, :next_cyclic)
  end

  @doc """
  Replaces the raw item set of an active change-driven subscription.

  A successful response returns an updated handle with the same remote job ID
  and optional new initial snapshot.
  """
  @spec modify_cyclic_raw(t(), S7.Cyclic.Subscription.t(), [binary()], keyword()) ::
          {:ok, S7.Cyclic.Subscription.t()} | {:error, Error.t()}
  def modify_cyclic_raw(client, subscription, item_specs, opts \\ [])

  def modify_cyclic_raw(client, %S7.Cyclic.Subscription{} = subscription, item_specs, opts) do
    with {:ok, options} <-
           Cyclic.validate_modify_options(opts, subscription.interval, :modify_cyclic) do
      call(
        fn -> Cyclic.modify(client, subscription, item_specs, options) end,
        :modify_cyclic
      )
    end
  end

  def modify_cyclic_raw(_client, _subscription, _item_specs, _opts),
    do: {:error, Error.new(:client, :modify_cyclic, :invalid_cyclic_subscription)}

  @doc """
  Releases a remote cyclic job and its local bounded queue.

  If the remote outcome is ambiguous, the connection is invalidated so a
  stale job ID cannot be reused in a later session.
  """
  @spec unsubscribe_cyclic(t(), S7.Cyclic.Subscription.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def unsubscribe_cyclic(client, subscription, opts \\ []) do
    with {:ok, options} <- Cyclic.validate_unsubscribe_options(opts, :unsubscribe_cyclic) do
      call(
        fn -> Cyclic.unsubscribe(client, subscription, options) end,
        :unsubscribe_cyclic
      )
    end
  end

  @doc """
  Starts a connection-scoped classic alarm-message subscription.

  `alarm_type` must be `:alarm_s` for the S7-300-style alarm path or
  `:alarm_8` for the S7-400-style path. Options are `:subscription_key`
  (exactly eight bytes), `:queue_limit`, `:timeout`, and `:step_timeout`.

  The returned handle belongs to the calling process and current S7 session.
  Events are delivered in wire order without deduplication.
  """
  @spec subscribe_alarms(t(), S7.Alarm.Subscription.alarm_type(), keyword()) ::
          {:ok, S7.Alarm.Subscription.t()} | {:error, Error.t()}
  def subscribe_alarms(client, alarm_type, opts \\ []) do
    with {:ok, options} <-
           Alarm.validate_subscription_options(opts, :subscribe_alarms) do
      call(fn -> Alarm.subscribe(client, alarm_type, options) end, :subscribe_alarms)
    end
  end

  @doc """
  Pulls the next bounded alarm or notification indication.

  A timeout leaves the remote subscription active. The caller must be the
  process that created the subscription handle.
  """
  @spec next_alarm(t(), S7.Alarm.Subscription.t(), pos_integer()) ::
          {:ok, S7.Alarm.Event.t()} | {:error, Error.t()}
  def next_alarm(client, subscription, timeout \\ 5_000) do
    call(fn -> Alarm.next(client, subscription, timeout) end, :next_alarm)
  end

  @doc """
  Releases a remote alarm subscription and its bounded local queue.

  A missing or malformed remote response invalidates the session because the
  remote subscription state would otherwise be ambiguous.
  """
  @spec unsubscribe_alarms(t(), S7.Alarm.Subscription.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def unsubscribe_alarms(client, subscription, opts \\ []) do
    with {:ok, options} <- Alarm.validate_request_options(opts, :unsubscribe_alarms) do
      call(
        fn -> Alarm.unsubscribe(client, subscription, options) end,
        :unsubscribe_alarms
      )
    end
  end

  @doc """
  Queries the PLC's currently buffered alarms for one classic alarm family.

  Query record headers are decoded while CPU-specific tails and complete wire
  records remain available in `S7.Alarm.Query`.
  """
  @spec query_alarms(t(), S7.Alarm.Subscription.alarm_type()) ::
          {:ok, S7.Alarm.Query.t()} | {:error, Error.t()}
  def query_alarms(client, alarm_type) do
    call(
      fn -> Alarm.query(client, {:alarm_type, alarm_type}) end,
      :query_alarms
    )
  end

  @doc """
  Queries one classic alarm event ID.
  """
  @spec query_alarm(t(), 0..0xFFFFFFFF) :: {:ok, S7.Alarm.Query.t()} | {:error, Error.t()}
  def query_alarm(client, event_id) do
    call(fn -> Alarm.query(client, {:event_id, event_id}, :query_alarm) end, :query_alarm)
  end

  @doc """
  Explicitly acknowledges one alarm object or acknowledgment struct.

  This operation changes PLC alarm state and is never replayed. A timeout or
  malformed response after transmission returns an indeterminate outcome and
  invalidates the session.
  """
  @spec acknowledge_alarm(
          t(),
          S7.Alarm.Acknowledgement.t() | S7.Alarm.Event.Object.t(),
          keyword()
        ) :: :ok | {:error, Error.t()}
  def acknowledge_alarm(client, acknowledgement, opts \\ []) do
    with {:ok, options} <- Alarm.validate_request_options(opts, :acknowledge_alarm),
         {:ok, results} <-
           call(
             fn ->
               Alarm.acknowledge(client, acknowledgement, options, :acknowledge_alarm)
             end,
             :acknowledge_alarm
           ) do
      single_acknowledgement_result(results)
    end
  end

  @doc """
  Explicitly acknowledges every object in an alarm event or list.

  Results preserve input order and report PLC item errors individually.
  """
  @spec acknowledge_alarms(
          t(),
          S7.Alarm.Event.t() | [S7.Alarm.Acknowledgement.t() | S7.Alarm.Event.Object.t()],
          keyword()
        ) :: {:ok, [S7.Alarm.Acknowledgement.Result.t()]} | {:error, Error.t()}
  def acknowledge_alarms(client, acknowledgements, opts \\ []) do
    with {:ok, options} <- Alarm.validate_request_options(opts, :acknowledge_alarms) do
      call(
        fn ->
          Alarm.acknowledge(client, acknowledgements, options, :acknowledge_alarms)
        end,
        :acknowledge_alarms
      )
    end
  end

  @doc """
  Returns the number of blocks in each directory type advertised by the PLC.

  Unknown block type codes are retained in `S7.Block.Inventory.counts`.
  """
  @spec block_counts(t()) :: {:ok, Block.Inventory.t()} | {:error, Error.t()}
  def block_counts(client), do: call(fn -> Connection.block_counts(client) end, :block_counts)

  @doc """
  Lists block identities, flags, and source languages for one block type.

  Large directories are assembled from bounded userdata fragments. Options are
  `:max_bytes` and `:max_fragments`.
  """
  @spec list_blocks(t(), Block.known_type(), keyword()) ::
          {:ok, [Block.Entry.t()]} | {:error, Error.t()}
  def list_blocks(client, type, opts \\ []) do
    with {:ok, type} <- Block.validate_request_type(type, :list_blocks),
         {:ok, limits} <- Block.validate_list_options(opts, :list_blocks) do
      call(fn -> Connection.list_blocks(client, type, limits) end, :list_blocks)
    end
  end

  @doc """
  Reads detailed metadata for one PLC block.

  Accepts either a `%S7.Block{}` or a block type and number.
  """
  @spec block_info(t(), Block.t()) :: {:ok, Block.Info.t()} | {:error, Error.t()}
  def block_info(client, %Block{} = block) do
    with {:ok, block} <- Block.validate(block, :block_info) do
      call(fn -> Connection.block_info(client, block) end, :block_info)
    end
  end

  @spec block_info(t(), Block.known_type(), 0..0xFFFF) ::
          {:ok, Block.Info.t()} | {:error, Error.t()}
  def block_info(client, type, number) do
    with {:ok, block} <- Block.normalize(type, number, :block_info) do
      call(fn -> Connection.block_info(client, block) end, :block_info)
    end
  end

  @doc """
  Uploads and parses one complete classic load-memory block image.

  The operation reserves the connection for the stateful upload sequence.
  Options are `:max_bytes`, `:max_fragments`, `:timeout`, and `:step_timeout`.
  """
  @spec upload_block(t(), Block.t(), keyword()) ::
          {:ok, Block.Image.t()} | {:error, Error.t()}
  def upload_block(client, block, opts \\ [])

  def upload_block(client, %Block{} = block, opts) do
    upload_block_operation(client, block, opts, false)
  end

  @spec upload_block(t(), Block.known_type(), 0..0xFFFF) ::
          {:ok, Block.Image.t()} | {:error, Error.t()}
  def upload_block(client, type, number), do: upload_block(client, type, number, [])

  @spec upload_block(t(), Block.known_type(), 0..0xFFFF, keyword()) ::
          {:ok, Block.Image.t()} | {:error, Error.t()}
  def upload_block(client, type, number, opts) do
    with {:ok, block} <- Block.normalize(type, number, :upload_block) do
      upload_block_operation(client, block, opts, false)
    end
  end

  @doc """
  Uploads one complete classic load-memory block image without parsing it.
  """
  @spec upload_block_raw(t(), Block.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def upload_block_raw(client, block, opts \\ [])

  def upload_block_raw(client, %Block{} = block, opts) do
    upload_block_operation(client, block, opts, true)
  end

  @spec upload_block_raw(t(), Block.known_type(), 0..0xFFFF) ::
          {:ok, binary()} | {:error, Error.t()}
  def upload_block_raw(client, type, number), do: upload_block_raw(client, type, number, [])

  @spec upload_block_raw(t(), Block.known_type(), 0..0xFFFF, keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def upload_block_raw(client, type, number, opts) do
    with {:ok, block} <- Block.normalize(type, number, :upload_block) do
      upload_block_operation(client, block, opts, true)
    end
  end

  @doc """
  Downloads and activates one parsed classic load-memory block image.

  The connection must be opened with `allow_destructive: true`, and this call
  requires `confirm: :download_block`. The PLC may replace an existing block;
  use `replace_block/3` when replacement is the caller's explicit intent.
  """
  @spec download_block(t(), Block.Image.t(), keyword()) :: :ok | {:error, Error.t()}
  def download_block(client, image, opts \\ [])

  def download_block(client, %Block.Image{} = image, opts) do
    download_block_operation(client, image, opts, :download_block, :download_block)
  end

  def download_block(_client, _image, _opts),
    do: {:error, Error.new(:client, :download_block, :invalid_block_image)}

  @doc """
  Validates, downloads, and activates a raw load-memory image for one block.
  """
  @spec download_block_raw(t(), Block.t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def download_block_raw(client, block, raw, opts \\ [])

  def download_block_raw(client, %Block{} = block, raw, opts) do
    download_raw_operation(client, block, raw, opts, :download_block, :download_block)
  end

  @spec download_block_raw(t(), Block.known_type(), 0..0xFFFF, binary()) ::
          :ok | {:error, Error.t()}
  def download_block_raw(client, type, number, raw),
    do: download_block_raw(client, type, number, raw, [])

  @spec download_block_raw(t(), Block.known_type(), 0..0xFFFF, binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def download_block_raw(client, type, number, raw, opts) do
    with {:ok, block} <- Block.normalize(type, number, :download_block) do
      download_raw_operation(client, block, raw, opts, :download_block, :download_block)
    end
  end

  @doc """
  Replaces a block through the classic download and activation sequence.

  Requires `allow_destructive: true` on the connection and
  `confirm: :replace_block` on this call.
  """
  @spec replace_block(t(), Block.Image.t(), keyword()) :: :ok | {:error, Error.t()}
  def replace_block(client, image, opts \\ [])

  def replace_block(client, %Block.Image{} = image, opts) do
    download_block_operation(client, image, opts, :replace_block, :replace_block)
  end

  def replace_block(_client, _image, _opts),
    do: {:error, Error.new(:client, :replace_block, :invalid_block_image)}

  @doc """
  Validates and replaces a block from its raw load-memory image.
  """
  @spec replace_block_raw(t(), Block.t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def replace_block_raw(client, block, raw, opts \\ [])

  def replace_block_raw(client, %Block{} = block, raw, opts) do
    download_raw_operation(client, block, raw, opts, :replace_block, :replace_block)
  end

  @spec replace_block_raw(t(), Block.known_type(), 0..0xFFFF, binary()) ::
          :ok | {:error, Error.t()}
  def replace_block_raw(client, type, number, raw),
    do: replace_block_raw(client, type, number, raw, [])

  @spec replace_block_raw(t(), Block.known_type(), 0..0xFFFF, binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def replace_block_raw(client, type, number, raw, opts) do
    with {:ok, block} <- Block.normalize(type, number, :replace_block) do
      download_raw_operation(client, block, raw, opts, :replace_block, :replace_block)
    end
  end

  @doc """
  Deletes one classic PLC block.

  Requires `allow_destructive: true` on the connection and
  `confirm: :delete_block` on this call.
  """
  @spec delete_block(t(), Block.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete_block(client, block, opts \\ [])

  def delete_block(client, %Block{} = block, opts) do
    with {:ok, block} <- Block.validate(block, :delete_block),
         {:ok, limits} <-
           Destructive.validate_options(opts, :delete_block, :delete_block) do
      call(fn -> BlockDownloader.delete(client, block, limits, :delete_block) end, :delete_block)
    end
  end

  @spec delete_block(t(), Block.known_type(), 0..0xFFFF) :: :ok | {:error, Error.t()}
  def delete_block(client, type, number), do: delete_block(client, type, number, [])

  @spec delete_block(t(), Block.known_type(), 0..0xFFFF, keyword()) ::
          :ok | {:error, Error.t()}
  def delete_block(client, type, number, opts) do
    with {:ok, block} <- Block.normalize(type, number, :delete_block) do
      delete_block(client, block, opts)
    end
  end

  @doc """
  Stops CPU program execution.

  Requires `allow_destructive: true` on the connection and
  `confirm: :stop_cpu` on this call.
  """
  @spec stop_cpu(t(), keyword()) :: :ok | {:error, Error.t()}
  def stop_cpu(client, opts \\ []), do: control(client, :stop_cpu, opts)

  @doc """
  Performs a warm CPU start (`P_PROGRAM` without a cold-start argument).

  Requires `allow_destructive: true` on the connection and
  `confirm: :warm_start_cpu` on this call.
  """
  @spec warm_start_cpu(t(), keyword()) :: :ok | {:error, Error.t()}
  def warm_start_cpu(client, opts \\ []), do: control(client, :warm_start_cpu, opts)

  @doc """
  Performs a cold CPU start (`P_PROGRAM` with the `C ` argument).

  Requires `allow_destructive: true` on the connection and
  `confirm: :cold_start_cpu` on this call.
  """
  @spec cold_start_cpu(t(), keyword()) :: :ok | {:error, Error.t()}
  def cold_start_cpu(client, opts \\ []), do: control(client, :cold_start_cpu, opts)

  @doc """
  Copies PLC work memory from RAM to load memory.

  The PLC commonly requires STOP mode. This call requires
  `allow_destructive: true` and `confirm: :copy_ram_to_rom`.
  """
  @spec copy_ram_to_rom(t(), keyword()) :: :ok | {:error, Error.t()}
  def copy_ram_to_rom(client, opts \\ []), do: control(client, :copy_ram_to_rom, opts)

  @doc """
  Requests PLC memory compression.

  The PLC commonly requires STOP mode. This call requires
  `allow_destructive: true` and `confirm: :compress_memory`.
  """
  @spec compress_memory(t(), keyword()) :: :ok | {:error, Error.t()}
  def compress_memory(client, opts \\ []), do: control(client, :compress_memory, opts)

  @doc """
  Returns negotiated connection information.
  """
  @spec info(t()) :: map() | {:error, Error.t()}
  def info(client), do: call(fn -> Connection.info(client) end, :info)

  @doc """
  Starts a fresh session on a disconnected long-lived client.

  In-flight operations from a failed session are never replayed.
  """
  @spec reconnect(t()) :: :ok | {:error, Error.t()}
  def reconnect(client), do: call(fn -> Connection.connect(client) end, :connect)

  @doc """
  Closes the TCP connection and stops its owner process.

  The default `mode: :immediate` fails accepted work. `mode: :drain` rejects
  new calls and waits up to `:timeout` milliseconds for accepted work.
  """
  @spec close(t(), keyword()) :: :ok | {:error, Error.t()}
  def close(client, opts \\ []) do
    case call(fn -> Connection.close(client, opts) end, :close) do
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

  defp finish_start_link(connection, opts) do
    case call(fn -> Connection.connect(connection) end, :connect) do
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

  defp fetch_start_host(opts) do
    case Keyword.fetch(opts, :host) do
      {:ok, host} -> {:ok, host}
      :error -> {:error, Error.new(:client, :connect, :missing_host)}
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

  defp read_szl_operation(client, id, index, opts, operation) do
    with {:ok, limits} <- SZL.validate_request(id, index, opts, operation) do
      call(fn -> Connection.read_szl(client, id, index, limits, operation) end, operation)
    end
  end

  defp upload_block_operation(client, block, opts, raw?) do
    with {:ok, block} <- Block.validate(block, :upload_block),
         {:ok, limits} <- BlockUploader.validate_options(opts, :upload_block) do
      call(
        fn -> BlockUploader.upload(client, block, limits, raw?, :upload_block) end,
        :upload_block
      )
    end
  end

  defp download_raw_operation(client, block, raw, opts, confirmation, operation) do
    with {:ok, image} <- Block.Image.decode(raw, block, operation) do
      download_block_operation(client, image, opts, confirmation, operation)
    end
  end

  defp download_block_operation(client, image, opts, confirmation, operation) do
    with {:ok, limits} <- Destructive.validate_options(opts, confirmation, operation),
         {:ok, image} <- Block.Image.decode(image.raw, image.block, operation) do
      call(fn -> BlockDownloader.download(client, image, limits, operation) end, operation)
    end
  end

  defp control(client, action, opts) do
    with {:ok, limits} <- Destructive.validate_options(opts, action, action) do
      call(fn -> DestructiveRequest.control(client, action, limits, action) end, action)
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

  defp single_acknowledgement_result([
         %S7.Alarm.Acknowledgement.Result{status: :ok}
       ]),
       do: :ok

  defp single_acknowledgement_result([
         %S7.Alarm.Acknowledgement.Result{status: :error, error: %Error{} = error}
       ]),
       do: {:error, %{error | operation: :acknowledge_alarm}}

  defp single_acknowledgement_result(_results),
    do: {:error, Error.new(:client, :acknowledge_alarm, :invalid_alarm_acknowledgement)}

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
