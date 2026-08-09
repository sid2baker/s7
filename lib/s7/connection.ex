defmodule S7.Connection do
  @moduledoc """
  Stateful S7 connection process.

  This `:gen_statem` owns the TCP socket, queues callers, and correlates active
  requests by S7 PDU reference. Callers interact through `S7`; protocol
  modules remain independent of this lifecycle layer.
  """

  @behaviour :gen_statem

  alias S7.{Address, Error, Result, SessionPassword, Telemetry, TSAP}

  alias S7.Connection.{
    Exclusive,
    Reconnect,
    Request,
    Stream,
    Subscription
  }

  alias S7.Protocol.Blocks, as: BlocksProtocol
  alias S7.Protocol.Clock, as: ClockProtocol
  alias S7.Protocol.{PDU, PDUPlanner, ReadVar, SetupCommunication, UserData, WriteVar}
  alias S7.Protocol.Security, as: SecurityProtocol
  alias S7.Protocol.SZL, as: SZLProtocol
  alias S7.Transport.{COTP, TPKT}

  alias S7.Transport.COTP.{
    ConnectionConfirm,
    ConnectionRequest,
    Data,
    DisconnectConfirm,
    DisconnectRequest,
    ErrorTPDU
  }

  @default_port 102
  @default_timeout 5_000
  @default_tpdu_size 1024
  @default_pdu_size 480
  @default_maximum_items 20
  @default_queue_limit 64
  @default_reconnect_min_delay 250
  @default_reconnect_max_delay 30_000
  @default_reconnect_jitter 0.2
  @default_transaction_timeout 30_000
  @default_transaction_message_limit 1_024
  @default_transaction_byte_limit 1_048_576
  @default_transaction_inbox_limit 64
  @default_subscription_limit 16
  @default_subscription_queue_limit 64
  @minimum_fragment_limit 64
  @maximum_fragment_limit 1024
  @maximum_tpkt_size 0xFFFF
  @maximum_receive_buffer_size 1_048_576
  @connection_options [
    :allow_destructive,
    :connection_type,
    :dst_tsap,
    :initial_reference,
    :max_items_per_pdu,
    :max_jobs,
    :max_tpkt_size,
    :name,
    :pdu_size,
    :port,
    :queue_limit,
    :rack,
    :receive_buffer_limit,
    :reconnect,
    :reconnect_jitter,
    :reconnect_max_attempts,
    :reconnect_max_delay,
    :reconnect_min_delay,
    :slot,
    :src_tsap,
    :subscription_limit,
    :timeout,
    :tpdu_size
  ]

  defstruct [
    :host,
    :port,
    :socket,
    :timeout,
    :src_tsap,
    :dst_tsap,
    :requested_tpdu_size,
    :tpdu_size,
    :requested_setup,
    :negotiated_setup,
    :pdu_size,
    :max_jobs,
    :max_items_per_pdu,
    :max_queue_size,
    :allow_destructive,
    :reference,
    :receive_buffer_limit,
    :stream,
    :reconnect,
    :drain,
    :close,
    :exclusive,
    :exclusive_waiter,
    :subscription_registry,
    receive_buffer: <<>>,
    max_tpkt_size: @maximum_tpkt_size,
    queue: {[], []},
    queued_count: 0,
    pending: %{},
    request_index: %{},
    session: %{local_reference: nil, remote_reference: nil, authenticated: false}
  ]

  @type state_name ::
          :disconnected
          | :tcp_connected
          | :cotp_connected
          | :s7_negotiating
          | :ready
          | :reconnecting
          | :draining
          | :disconnecting

  @type t :: %__MODULE__{}

  @doc false
  @spec start(term(), keyword()) :: :gen_statem.start_ret()
  def start(host, opts \\ []) do
    start_statem(:start, host, opts)
  end

  @doc false
  @spec start_link(term(), keyword()) :: :gen_statem.start_ret()
  def start_link(host, opts \\ []) do
    start_statem(:start_link, host, opts)
  end

  @doc false
  @spec connect(pid()) :: :ok | {:error, Error.t()}
  def connect(connection), do: :gen_statem.call(connection, :connect, :infinity)

  @doc false
  @spec read(pid(), Address.t(), boolean()) ::
          {:ok, S7.Data.value() | binary()} | {:error, Error.t()}
  def read(connection, address, raw?) do
    :gen_statem.call(connection, {:read, address, raw?}, :infinity)
  end

  @doc false
  @spec read_many(pid(), [Address.t()], boolean()) ::
          {:ok, [Result.t()]} | {:error, Error.t(), [Result.t()]}
  def read_many(connection, addresses, raw?) do
    :gen_statem.call(connection, {:read_many, addresses, raw?}, :infinity)
  end

  @doc false
  @spec write(pid(), Address.t(), binary()) :: :ok | {:error, Error.t()}
  def write(connection, address, value) do
    :gen_statem.call(connection, {:write, address, value}, :infinity)
  end

  @doc false
  @spec write_many(pid(), [{Address.t(), binary()}]) ::
          {:ok, [Result.t()]} | {:error, Error.t(), [Result.t()]}
  def write_many(connection, items) do
    :gen_statem.call(connection, {:write_many, items}, :infinity)
  end

  @doc false
  @spec userdata(pid(), UserData.t(), atom()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def userdata(connection, message, operation \\ :userdata) do
    :gen_statem.call(connection, {:userdata, message, operation}, :infinity)
  end

  @doc false
  @spec read_szl(pid(), 0..0xFFFF, 0..0xFFFF, S7.SZL.limits(), atom()) ::
          {:ok, S7.SZL.t()} | {:error, Error.t()}
  def read_szl(connection, id, index, limits, operation) do
    :gen_statem.call(connection, {:read_szl, id, index, limits, operation}, :infinity)
  end

  @doc false
  @spec block_counts(pid()) :: {:ok, S7.Block.Inventory.t()} | {:error, Error.t()}
  def block_counts(connection) do
    :gen_statem.call(connection, {:blocks, :counts}, :infinity)
  end

  @doc false
  @spec list_blocks(pid(), S7.Block.known_type(), S7.Block.limits()) ::
          {:ok, [S7.Block.Entry.t()]} | {:error, Error.t()}
  def list_blocks(connection, type, limits) do
    :gen_statem.call(connection, {:blocks, :list, type, limits}, :infinity)
  end

  @doc false
  @spec block_info(pid(), S7.Block.t()) :: {:ok, S7.Block.Info.t()} | {:error, Error.t()}
  def block_info(connection, block) do
    :gen_statem.call(connection, {:blocks, :info, block}, :infinity)
  end

  @doc false
  @spec read_clock(pid()) :: {:ok, S7.PLC.Clock.t()} | {:error, Error.t()}
  def read_clock(connection), do: :gen_statem.call(connection, {:clock, :read}, :infinity)

  @doc false
  @spec set_clock(pid(), NaiveDateTime.t()) :: :ok | {:error, Error.t()}
  def set_clock(connection, datetime) do
    :gen_statem.call(connection, {:clock, :set, datetime}, :infinity)
  end

  @doc false
  @spec authenticate(pid(), SessionPassword.t()) :: :ok | {:error, Error.t()}
  def authenticate(connection, password) do
    :gen_statem.call(connection, {:security, :login, password}, :infinity)
  end

  @doc false
  @spec logout(pid()) :: :ok | {:error, Error.t()}
  def logout(connection), do: :gen_statem.call(connection, {:security, :logout}, :infinity)

  @doc false
  @spec begin_transaction(pid(), atom(), keyword()) ::
          {:ok, reference()} | {:error, Error.t()}
  def begin_transaction(connection, operation, opts \\ []) do
    :gen_statem.call(connection, {:begin_transaction, operation, opts}, :infinity)
  end

  @doc false
  @spec transaction_request(pid(), reference(), PDU.t()) ::
          {:ok, PDU.t()} | {:error, Error.t()}
  def transaction_request(connection, token, %PDU{} = pdu) do
    :gen_statem.call(connection, {:transaction_request, token, pdu}, :infinity)
  end

  @doc false
  @spec transaction_receive(pid(), reference(), pos_integer()) ::
          {:ok, PDU.t()} | {:error, Error.t()}
  def transaction_receive(connection, token, timeout \\ @default_timeout) do
    :gen_statem.call(connection, {:transaction_receive, token, timeout}, :infinity)
  end

  @doc false
  @spec transaction_reply(pid(), reference(), PDU.t()) :: :ok | {:error, Error.t()}
  def transaction_reply(connection, token, %PDU{} = pdu) do
    :gen_statem.call(connection, {:transaction_reply, token, pdu}, :infinity)
  end

  @doc false
  @spec end_transaction(pid(), reference()) :: :ok | {:error, Error.t()}
  def end_transaction(connection, token) do
    :gen_statem.call(connection, {:end_transaction, token}, :infinity)
  end

  @doc false
  @spec abort_transaction(pid(), reference(), Error.t()) :: :ok | {:error, Error.t()}
  def abort_transaction(connection, token, %Error{} = error) do
    :gen_statem.call(connection, {:abort_transaction, token, error}, :infinity)
  end

  @doc false
  @spec subscribe_userdata(pid(), Subscription.filter(), keyword()) ::
          {:ok, reference()} | {:error, Error.t()}
  def subscribe_userdata(connection, filter, opts \\ []) do
    :gen_statem.call(connection, {:subscribe_userdata, filter, opts}, :infinity)
  end

  @doc false
  @spec rebind_userdata_subscription(pid(), reference(), Subscription.filter()) ::
          :ok | {:error, Error.t()}
  def rebind_userdata_subscription(connection, subscription, filter) do
    :gen_statem.call(
      connection,
      {:rebind_userdata_subscription, subscription, filter},
      :infinity
    )
  end

  @doc false
  @spec validate_userdata_subscription(pid(), reference()) :: :ok | {:error, Error.t()}
  def validate_userdata_subscription(connection, subscription) do
    :gen_statem.call(connection, {:validate_userdata_subscription, subscription}, :infinity)
  end

  @doc false
  @spec next_userdata(pid(), reference(), pos_integer()) ::
          {:ok, UserData.t()} | {:error, Error.t()}
  def next_userdata(connection, subscription, timeout \\ @default_timeout) do
    :gen_statem.call(connection, {:next_userdata, subscription, timeout}, :infinity)
  end

  @doc false
  @spec unsubscribe_userdata(pid(), reference()) :: :ok | {:error, Error.t()}
  def unsubscribe_userdata(connection, subscription) do
    :gen_statem.call(connection, {:unsubscribe_userdata, subscription}, :infinity)
  end

  @doc false
  @spec close(:gen_statem.server_ref(), keyword()) :: :ok | {:error, Error.t()}
  def close(connection, opts \\ []),
    do: :gen_statem.call(connection, {:close, opts}, :infinity)

  @doc false
  @spec info(pid()) :: map() | {:error, Error.t()}
  def info(connection), do: :gen_statem.call(connection, :info, :infinity)

  @doc false
  @spec next_reference(0..0xFFFF) :: 1..0xFFFF
  def next_reference(0xFFFF), do: 1
  def next_reference(reference) when reference in 0..0xFFFE, do: reference + 1

  defp start_statem(mode, host, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case normalize_name(Keyword.get(opts, :name)) do
        {:ok, nil} -> apply(:gen_statem, mode, [__MODULE__, {host, opts}, []])
        {:ok, name} -> apply(:gen_statem, mode, [name, __MODULE__, {host, opts}, []])
        {:error, error} -> {:error, error}
      end
    else
      {:error, Error.new(:client, :connect, :invalid_options, details: %{options: opts})}
    end
  end

  defp start_statem(mode, host, opts),
    do: apply(:gen_statem, mode, [__MODULE__, {host, opts}, []])

  defp normalize_name(nil), do: {:ok, nil}
  defp normalize_name(name) when is_atom(name), do: {:ok, {:local, name}}
  defp normalize_name({:local, name} = registration) when is_atom(name), do: {:ok, registration}
  defp normalize_name({:global, _name} = registration), do: {:ok, registration}

  defp normalize_name({:via, module, _name} = registration) when is_atom(module),
    do: {:ok, registration}

  defp normalize_name(name),
    do:
      {:error,
       Error.new(:client, :connect, :invalid_option, details: %{option: :name, value: name})}

  @impl :gen_statem
  def callback_mode, do: :handle_event_function

  @impl :gen_statem
  def init({host, opts}) do
    case build_state(host, opts) do
      {:ok, data} -> {:ok, :disconnected, data}
      {:error, error} -> {:stop, error}
    end
  end

  @impl :gen_statem
  def handle_event({:call, from}, :connect, :disconnected, data) do
    data = reset_reconnect(data)

    case open_tcp(data) do
      {:ok, data} ->
        {:next_state, :tcp_connected, data, [{:next_event, :internal, {:connect_cotp, from}}]}

      {:error, error} ->
        connection_failed(data, error, from)
    end
  end

  def handle_event(:internal, {:connect_cotp, from}, :tcp_connected, data) do
    case negotiate_cotp(data) do
      {:ok, data} ->
        {:next_state, :cotp_connected, data, [{:next_event, :internal, {:negotiate_s7, from}}]}

      {:error, error, data} ->
        connection_failed(data, error, from)
    end
  end

  def handle_event(:internal, {:negotiate_s7, from}, :cotp_connected, data) do
    reference = data.reference
    data = %{data | reference: next_reference(data.reference)}

    case negotiate_s7(data, reference) do
      {:ok, data} ->
        case activate_socket(data) do
          {:ok, data} ->
            telemetry_connection_connected(data, false)
            {:next_state, :ready, reset_reconnect(data), [{:reply, from, :ok}]}

          {:error, error} ->
            connection_failed(data, error, from)
        end

      {:error, error, data} ->
        connection_failed(data, error, from)
    end
  end

  def handle_event(
        :info,
        {:reconnect, token},
        :reconnecting,
        %{reconnect: %Reconnect{token: token} = reconnect} = data
      ) do
    reconnect = %{
      reconnect
      | timer: nil,
        token: nil,
        attempts: reconnect.attempts + 1
    }

    data = %{data | reconnect: reconnect}

    case establish_connection(data) do
      {:ok, data} ->
        telemetry_connection_connected(data, true)
        {:next_state, :ready, reset_reconnect(data)}

      {:error, _error, data} ->
        data |> advance_reconnect_delay() |> reconnect_or_disconnect()
    end
  end

  def handle_event({:call, from}, :connect, state, _data) when state != :disconnected do
    error = Error.new(:client, :connect, :already_connected)
    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  def handle_event({:call, from}, {:read, _address, _raw?} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:write, _address, _value} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:read_many, _addresses, _raw?} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:write_many, _items} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event(
        {:call, from},
        {:userdata, _message, _request_operation} = operation,
        :ready,
        data
      ),
      do: submit_request(from, operation, data)

  def handle_event(
        {:call, from},
        {:read_szl, _id, _index, _limits, _request_operation} = operation,
        :ready,
        data
      ),
      do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:blocks, :counts} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event(
        {:call, from},
        {:blocks, :list, _type, _limits} = operation,
        :ready,
        data
      ),
      do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:blocks, :info, _block} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:clock, :read} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:clock, :set, _datetime} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:security, :login, _password} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:security, :logout} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event(
        {:call, from},
        {:begin_transaction, operation, opts},
        :ready,
        data
      ) do
    begin_exclusive(from, operation, opts, data)
  end

  def handle_event(
        {:call, from},
        {:transaction_request, token, %PDU{} = pdu},
        state,
        data
      )
      when state in [:ready, :draining] do
    submit_transaction_request(from, token, pdu, state, data)
  end

  def handle_event(
        {:call, from},
        {:transaction_receive, token, timeout},
        state,
        data
      )
      when state in [:ready, :draining] do
    receive_transaction_job(from, token, timeout, data)
  end

  def handle_event(
        {:call, from},
        {:transaction_reply, token, %PDU{} = pdu},
        state,
        data
      )
      when state in [:ready, :draining] do
    reply_transaction_job(from, token, pdu, state, data)
  end

  def handle_event({:call, from}, {:end_transaction, token}, state, data)
      when state in [:ready, :draining] do
    finish_exclusive(from, token, state, data)
  end

  def handle_event(
        {:call, from},
        {:abort_transaction, token, %Error{} = error},
        state,
        data
      )
      when state in [:ready, :draining] do
    abort_exclusive(from, token, error, state, data)
  end

  def handle_event(
        {:call, from},
        {:subscribe_userdata, filter, opts},
        :ready,
        data
      ) do
    subscribe_userdata_owner(from, filter, opts, data)
  end

  def handle_event(
        {:call, from},
        {:next_userdata, subscription, timeout},
        :ready,
        data
      ) do
    next_userdata_event(from, subscription, timeout, data)
  end

  def handle_event(
        {:call, from},
        {:rebind_userdata_subscription, subscription, filter},
        :ready,
        data
      ) do
    rebind_userdata_subscription_owner(from, subscription, filter, data)
  end

  def handle_event({:call, from}, {:validate_userdata_subscription, subscription}, :ready, data) do
    validate_userdata_subscription_owner(from, subscription, data)
  end

  def handle_event({:call, from}, {:unsubscribe_userdata, subscription}, :ready, data) do
    unsubscribe_userdata_owner(from, subscription, data)
  end

  def handle_event({:call, from}, {:close, opts}, :ready, data) do
    case close_options(opts, data.timeout) do
      {:ok, :immediate, timeout} -> close_immediately(from, data, timeout)
      {:ok, :drain, timeout} -> begin_drain(from, data, timeout)
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, {:close, opts}, :draining, data) do
    case close_options(opts, data.timeout) do
      {:ok, :immediate, timeout} -> close_immediately(from, data, timeout)
      {:ok, :drain, _timeout} -> reply_already_draining(from)
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, {:close, opts}, :disconnecting, data) do
    case close_options(opts, data.timeout) do
      {:ok, _mode, _timeout} -> reply_already_draining(from)
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, {:close, opts}, _state, data) do
    case close_options(opts, data.timeout) do
      {:ok, _mode, timeout} -> close_immediately(from, data, timeout)
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, operation, state, _data)
      when state != :ready and operation != :close and operation != :info do
    error =
      Error.new(:client, operation_name(operation), :not_connected, details: %{state: state})

    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  def handle_event({:call, from}, :info, state, data) do
    info = %{
      state: state,
      host: data.host,
      port: data.port,
      pdu_size: data.pdu_size,
      max_jobs: data.max_jobs,
      max_items_per_pdu: data.max_items_per_pdu,
      queue_limit: data.max_queue_size,
      queued_requests: data.queued_count,
      in_flight_requests: map_size(data.pending),
      tpdu_size: data.tpdu_size,
      next_reference: data.reference,
      socket_mode: if(data.socket, do: :active_once, else: :closed),
      reconnect: data.reconnect.enabled,
      reconnect_attempts: data.reconnect.attempts,
      reconnect_delay: data.reconnect.delay,
      destructive_operations: data.allow_destructive,
      exclusive_transaction: not is_nil(data.exclusive),
      transaction_waiting: not is_nil(data.exclusive_waiter),
      subscriptions: map_size(data.subscription_registry.entries),
      authenticated: data.session.authenticated
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  def handle_event(:info, {:tcp, socket, bytes}, state, %{socket: socket} = data)
      when state in [:ready, :draining] do
    case receive_active_bytes(data, bytes) do
      {:ok, data} ->
        case schedule_requests(data) do
          {:ok, data} -> after_active_event(state, data)
          {:disconnect, error, data} -> disconnect_with_error(state, data, error)
        end

      {:close_confirmed, data} ->
        complete_disconnect(data, Error.new(:cotp, :close, :disconnect_confirmed))

      {:disconnect, error, data} ->
        disconnect_with_error(state, data, error)
    end
  end

  def handle_event(:info, {:tcp, socket, bytes}, :disconnecting, %{socket: socket} = data) do
    case receive_active_bytes(data, bytes) do
      {:close_confirmed, data} ->
        complete_disconnect(data, Error.new(:cotp, :close, :disconnect_confirmed))

      {:disconnect, error, data} ->
        complete_disconnect(data, with_operation(error, :close))

      {:ok, data} ->
        rearm_disconnect(data)
    end
  end

  def handle_event(:info, {:request_timeout, reference, token}, state, data)
      when state in [:ready, :draining] do
    case data.pending do
      %{^reference => %Request{timer_token: ^token} = request} ->
        error = Error.new(:tcp, request.operation, :timeout)
        disconnect_with_error(state, data, error)

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:DOWN, monitor, :process, _pid, _reason}, state, data)
      when state in [:ready, :draining] do
    case handle_owner_down(data, monitor) do
      {:exclusive, error, data} ->
        disconnect_with_error(state, data, error)

      {:session_bound, error, data} ->
        disconnect_with_error(state, data, error)

      {:ok, data} ->
        continue_after_owner_down(state, data)
    end
  end

  def handle_event(
        :info,
        {:drain_timeout, token},
        :draining,
        %{drain: %{token: token}} = data
      ) do
    error = Error.new(:client, :close, :drain_timeout)
    fail_drain(data, error)
  end

  def handle_event(
        :info,
        {:disconnect_timeout, token},
        :disconnecting,
        %{close: %{token: token}} = data
      ) do
    complete_disconnect(data, Error.new(:cotp, :close, :disconnect_timeout))
  end

  def handle_event(
        :info,
        {:transaction_timeout, token},
        state,
        %{exclusive: %Exclusive{timer_token: token} = exclusive} = data
      )
      when state in [:ready, :draining] do
    error = Error.new(:client, exclusive.operation, :transaction_timeout)
    disconnect_with_error(state, data, error)
  end

  def handle_event(
        :info,
        {:transaction_timeout, token},
        state,
        %{exclusive_waiter: %Exclusive{timer_token: token} = exclusive} = data
      )
      when state in [:ready, :draining] do
    error = Error.new(:client, exclusive.operation, :transaction_timeout)
    :gen_statem.reply(exclusive.from, {:error, error})
    data = clear_exclusive_waiter(data)

    case schedule_requests(data) do
      {:ok, data} -> after_owner_cleanup(state, data)
      {:disconnect, schedule_error, data} -> disconnect_with_error(state, data, schedule_error)
    end
  end

  def handle_event(
        :info,
        {:transaction_receive_timeout, token},
        state,
        %{exclusive: %Exclusive{receive_token: token} = exclusive} = data
      )
      when state in [:ready, :draining] do
    error = Error.new(:client, exclusive.operation, :timeout)
    :gen_statem.reply(exclusive.receive_from, {:error, error})
    exclusive = clear_transaction_receiver(exclusive)
    {:keep_state, %{data | exclusive: exclusive}}
  end

  def handle_event(
        :info,
        {:subscription_timeout, reference, token},
        :ready,
        data
      ) do
    timeout_subscription(reference, token, data)
  end

  def handle_event(:info, {:tcp_closed, socket}, :disconnecting, %{socket: socket} = data) do
    complete_disconnect(data, Error.new(:tcp, :close, :connection_closed))
  end

  def handle_event(
        :info,
        {:tcp_error, socket, reason},
        :disconnecting,
        %{socket: socket} = data
      ) do
    complete_disconnect(data, tcp_error(:close, reason))
  end

  def handle_event(:info, {:tcp_closed, socket}, state, %{socket: socket} = data) do
    error = Error.new(:tcp, :request, :connection_closed)
    telemetry_connection_disconnected(data, error)
    data = data |> fail_all_requests(error) |> reset_connection()
    connection_lost(state, data, error)
  end

  def handle_event(:info, {:tcp_error, socket, reason}, state, %{socket: socket} = data) do
    error = tcp_error(:request, reason)
    telemetry_connection_disconnected(data, error)
    data = data |> fail_all_requests(error) |> close_socket()
    connection_lost(state, data, error)
  end

  def handle_event(_event_type, _event_content, _state, _data), do: :keep_state_and_data

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    data |> cancel_reconnect() |> cancel_drain() |> cancel_close() |> close_socket()
    :ok
  end

  defp build_state(host, opts) when is_list(opts) do
    with :ok <- validate_connection_options(opts),
         :ok <- validate_host(host),
         {:ok, port} <- positive_option(opts, :port, @default_port, 0xFFFF),
         {:ok, timeout} <- positive_option(opts, :timeout, @default_timeout, :infinity),
         {:ok, max_tpkt_size} <-
           positive_option(opts, :max_tpkt_size, @maximum_tpkt_size, @maximum_tpkt_size),
         :ok <- validate_minimum_tpkt(max_tpkt_size),
         {:ok, receive_buffer_limit} <- receive_buffer_limit(opts, max_tpkt_size),
         {:ok, tpdu_size} <- tpdu_size(opts),
         :ok <- validate_transport_sizes(max_tpkt_size, tpdu_size),
         {:ok, pdu_size} <- positive_option(opts, :pdu_size, @default_pdu_size, 0xFFFF),
         :ok <- validate_minimum_pdu(pdu_size),
         {:ok, max_jobs} <- positive_option(opts, :max_jobs, 1, 0xFFFF),
         {:ok, max_items_per_pdu} <-
           positive_option(opts, :max_items_per_pdu, @default_maximum_items, 0xFF),
         {:ok, max_queue_size} <-
           nonnegative_option(
             opts,
             :queue_limit,
             @default_queue_limit,
             @maximum_receive_buffer_size
           ),
         {:ok, max_subscriptions} <-
           positive_option(
             opts,
             :subscription_limit,
             @default_subscription_limit,
             @maximum_receive_buffer_size
           ),
         {:ok, allow_destructive} <- boolean_option(opts, :allow_destructive, false),
         {:ok, reconnect} <- reconnect_options(opts),
         {:ok, src_tsap} <- source_tsap(opts),
         {:ok, dst_tsap} <- destination_tsap(opts),
         {:ok, reference} <- initial_reference(opts) do
      {:ok,
       %__MODULE__{
         host: host,
         port: port,
         timeout: timeout,
         src_tsap: src_tsap,
         dst_tsap: dst_tsap,
         requested_tpdu_size: tpdu_size,
         tpdu_size: tpdu_size,
         requested_setup: %SetupCommunication{
           max_amq_calling: max_jobs,
           max_amq_called: max_jobs,
           pdu_length: pdu_size
         },
         pdu_size: pdu_size,
         max_jobs: max_jobs,
         max_items_per_pdu: max_items_per_pdu,
         max_queue_size: max_queue_size,
         allow_destructive: allow_destructive,
         subscription_registry: %{limit: max_subscriptions, entries: %{}, monitor_index: %{}},
         reference: reference,
         receive_buffer_limit: receive_buffer_limit,
         max_tpkt_size: max_tpkt_size,
         stream: Stream.new(),
         reconnect: struct!(Reconnect, Map.put(reconnect, :delay, reconnect.min_delay)),
         drain: nil,
         close: nil
       }}
    end
  end

  defp build_state(_host, opts),
    do: {:error, Error.new(:client, :connect, :invalid_options, details: %{options: opts})}

  defp validate_connection_options(opts) do
    if Keyword.keyword?(opts) do
      validate_connection_option_keys(Keyword.keys(opts))
    else
      {:error, Error.new(:client, :connect, :invalid_options, details: %{options: opts})}
    end
  end

  defp validate_connection_option_keys(keys) do
    case Enum.find(keys, &(&1 not in @connection_options)) do
      nil ->
        :ok

      option ->
        {:error, Error.new(:client, :connect, :invalid_option, details: %{option: option})}
    end
  end

  defp validate_host(host) when is_binary(host) and byte_size(host) > 0, do: :ok

  defp validate_host(host) when is_tuple(host) do
    if :inet.is_ip_address(host) do
      :ok
    else
      {:error, Error.new(:tcp, :connect, :invalid_host, details: %{host: host})}
    end
  end

  defp validate_host(host) when is_list(host) and host != [], do: :ok

  defp validate_host(host),
    do: {:error, Error.new(:tcp, :connect, :invalid_host, details: %{host: host})}

  defp positive_option(opts, key, default, maximum) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 and (maximum == :infinity or value <= maximum) do
      {:ok, value}
    else
      {:error,
       Error.new(:client, :connect, :invalid_option, details: %{option: key, value: value})}
    end
  end

  defp nonnegative_option(opts, key, default, maximum) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value >= 0 and value <= maximum do
      {:ok, value}
    else
      {:error,
       Error.new(:client, :connect, :invalid_option, details: %{option: key, value: value})}
    end
  end

  defp reconnect_options(opts) do
    with {:ok, enabled} <- boolean_option(opts, :reconnect, false),
         {:ok, min_delay} <-
           positive_option(opts, :reconnect_min_delay, @default_reconnect_min_delay, :infinity),
         {:ok, max_delay} <-
           positive_option(opts, :reconnect_max_delay, @default_reconnect_max_delay, :infinity),
         :ok <- validate_reconnect_delays(min_delay, max_delay),
         {:ok, max_attempts} <- reconnect_max_attempts(opts),
         {:ok, jitter} <- reconnect_jitter(opts) do
      {:ok,
       %{
         enabled: enabled,
         min_delay: min_delay,
         max_delay: max_delay,
         max_attempts: max_attempts,
         jitter: jitter
       }}
    end
  end

  defp boolean_option(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_boolean(value) do
      {:ok, value}
    else
      {:error,
       Error.new(:client, :connect, :invalid_option, details: %{option: key, value: value})}
    end
  end

  defp validate_reconnect_delays(min_delay, max_delay) when min_delay <= max_delay, do: :ok

  defp validate_reconnect_delays(min_delay, max_delay) do
    {:error,
     Error.new(:client, :connect, :invalid_option,
       details: %{option: :reconnect_max_delay, value: max_delay, minimum: min_delay}
     )}
  end

  defp reconnect_max_attempts(opts) do
    value = Keyword.get(opts, :reconnect_max_attempts, :infinity)

    if value == :infinity or (is_integer(value) and value > 0) do
      {:ok, value}
    else
      {:error,
       Error.new(:client, :connect, :invalid_option,
         details: %{option: :reconnect_max_attempts, value: value}
       )}
    end
  end

  defp reconnect_jitter(opts) do
    value = Keyword.get(opts, :reconnect_jitter, @default_reconnect_jitter)

    if is_number(value) and value >= 0 and value <= 1 do
      {:ok, value / 1}
    else
      {:error,
       Error.new(:client, :connect, :invalid_option,
         details: %{option: :reconnect_jitter, value: value}
       )}
    end
  end

  defp tpdu_size(opts) do
    size = Keyword.get(opts, :tpdu_size, @default_tpdu_size)

    if COTP.valid_tpdu_size?(size) do
      {:ok, size}
    else
      {:error, Error.new(:cotp, :connect, :invalid_tpdu_size, details: %{tpdu_size: size})}
    end
  end

  defp validate_minimum_pdu(size) when size >= 32, do: :ok

  defp validate_minimum_pdu(size),
    do: {:error, Error.new(:s7, :connect, :invalid_pdu_size, details: %{pdu_size: size})}

  defp validate_minimum_tpkt(size) when size >= 7, do: :ok

  defp validate_minimum_tpkt(size),
    do: {:error, Error.new(:tpkt, :connect, :invalid_tpkt_size, details: %{max_tpkt_size: size})}

  defp validate_transport_sizes(max_tpkt_size, tpdu_size)
       when max_tpkt_size >= tpdu_size + 4,
       do: :ok

  defp validate_transport_sizes(max_tpkt_size, tpdu_size) do
    {:error,
     Error.new(:tpkt, :connect, :invalid_tpkt_size,
       details: %{
         max_tpkt_size: max_tpkt_size,
         minimum: tpdu_size + 4,
         tpdu_size: tpdu_size
       }
     )}
  end

  defp receive_buffer_limit(opts, max_tpkt_size) do
    limit =
      Keyword.get(
        opts,
        :receive_buffer_limit,
        min(max_tpkt_size * 2, @maximum_receive_buffer_size)
      )

    if is_integer(limit) and limit >= max_tpkt_size and limit <= @maximum_receive_buffer_size do
      {:ok, limit}
    else
      {:error,
       Error.new(:tcp, :connect, :invalid_option,
         details: %{option: :receive_buffer_limit, value: limit}
       )}
    end
  end

  defp source_tsap(opts) do
    opts
    |> Keyword.get(:src_tsap, <<0x01, 0x00>>)
    |> validate_tsap(:src_tsap)
  end

  defp destination_tsap(opts) do
    case Keyword.fetch(opts, :dst_tsap) do
      {:ok, tsap} -> validate_tsap(tsap, :dst_tsap)
      :error -> TSAP.build(opts)
    end
  end

  defp validate_tsap(tsap, _name) when is_binary(tsap) and byte_size(tsap) in 1..16,
    do: {:ok, tsap}

  defp validate_tsap(tsap, name),
    do:
      {:error,
       Error.new(:cotp, :connect, :invalid_tsap, details: %{parameter: name, value: tsap})}

  defp initial_reference(opts) do
    reference = Keyword.get(opts, :initial_reference, 1)

    if is_integer(reference) and reference in 0..0xFFFF do
      {:ok, reference}
    else
      {:error, Error.new(:s7, :connect, :invalid_pdu_reference, details: %{reference: reference})}
    end
  end

  defp open_tcp(data) do
    options = [:binary, active: false, packet: :raw, nodelay: true, keepalive: true]

    case :gen_tcp.connect(normalize_host(data.host), data.port, options, data.timeout) do
      {:ok, socket} -> {:ok, %{data | socket: socket, receive_buffer: <<>>}}
      {:error, reason} -> {:error, tcp_error(:connect, reason)}
    end
  end

  defp connection_failed(data, error, from) do
    data = close_socket(data)

    case schedule_reconnect(data) do
      {:ok, data} ->
        {:next_state, :reconnecting, data, [{:reply, from, {:error, error}}]}

      :disabled ->
        {:next_state, :disconnected, data, [{:reply, from, {:error, error}}]}
    end
  end

  defp establish_connection(data) do
    data = reset_session_limits(data)

    with {:ok, data} <- open_for_reconnect(data),
         {:ok, data} <- negotiate_cotp(data),
         {:ok, reference, data} <- reserve_setup_reference(data),
         {:ok, data} <- negotiate_s7(data, reference),
         {:ok, data} <- activate_for_reconnect(data) do
      {:ok, data}
    else
      {:error, %Error{} = error, data} -> {:error, error, close_socket(data)}
    end
  end

  defp open_for_reconnect(data) do
    case open_tcp(data) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, error, data}
    end
  end

  defp reserve_setup_reference(data) do
    {:ok, data.reference, %{data | reference: next_reference(data.reference)}}
  end

  defp activate_for_reconnect(data) do
    case activate_socket(data) do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, error, data}
    end
  end

  defp reconnect_or_disconnect(data) do
    case schedule_reconnect(data) do
      {:ok, data} -> {:next_state, :reconnecting, data}
      :disabled -> {:next_state, :disconnected, data}
    end
  end

  defp schedule_reconnect(data) do
    reconnect = data.reconnect

    if reconnect_allowed?(reconnect) do
      token = make_ref()

      delay =
        reconnect.delay
        |> jittered_delay(reconnect.jitter)
        |> min(reconnect.max_delay)

      timer = Process.send_after(self(), {:reconnect, token}, delay)
      telemetry_reconnect_scheduled(data, delay)
      {:ok, %{data | reconnect: %{reconnect | timer: timer, token: token}}}
    else
      :disabled
    end
  end

  defp reconnect_allowed?(%Reconnect{enabled: false}), do: false
  defp reconnect_allowed?(%Reconnect{max_attempts: :infinity}), do: true

  defp reconnect_allowed?(reconnect),
    do: reconnect.attempts < reconnect.max_attempts

  defp jittered_delay(delay, jitter) when jitter == 0, do: delay

  defp jittered_delay(delay, jitter) do
    factor = 1.0 - jitter + :rand.uniform() * jitter * 2
    max(round(delay * factor), 0)
  end

  defp advance_reconnect_delay(data) do
    reconnect = data.reconnect
    delay = min(reconnect.delay * 2, reconnect.max_delay)
    %{data | reconnect: %{reconnect | delay: delay}}
  end

  defp reset_reconnect(data) do
    data = cancel_reconnect(data)
    reconnect = %{data.reconnect | attempts: 0, delay: data.reconnect.min_delay}
    %{data | reconnect: reconnect}
  end

  defp cancel_reconnect(data) do
    cancel_timer(data.reconnect.timer)
    %{data | reconnect: %{data.reconnect | timer: nil, token: nil}}
  end

  defp reset_session_limits(data) do
    %{
      data
      | tpdu_size: data.requested_tpdu_size,
        pdu_size: data.requested_setup.pdu_length,
        max_jobs: min(data.requested_setup.max_amq_calling, data.requested_setup.max_amq_called)
    }
  end

  defp activate_socket(data) do
    case :inet.setopts(data.socket, active: :once) do
      :ok ->
        stream = Stream.new(data.receive_buffer)
        {:ok, %{data | receive_buffer: <<>>, stream: stream}}

      {:error, reason} ->
        {:error, tcp_error(:connect, reason)}
    end
  end

  defp after_active_event(:draining, data) do
    if requests_idle?(data), do: complete_drain(data), else: rearm_or_disconnect(:draining, data)
  end

  defp after_active_event(:ready, data), do: rearm_or_disconnect(:ready, data)

  defp rearm_or_disconnect(state, data) do
    case :inet.setopts(data.socket, active: :once) do
      :ok -> {:keep_state, data}
      {:error, reason} -> disconnect_with_error(state, data, tcp_error(:request, reason))
    end
  end

  defp disconnect_with_error(:draining, data, error), do: fail_drain(data, error)

  defp disconnect_with_error(_state, data, error) do
    telemetry_connection_disconnected(data, error)
    data = data |> fail_all_requests(error) |> close_socket()
    reconnect_or_disconnect(data)
  end

  defp connection_lost(:draining, data, error), do: fail_drain(data, error, false)
  defp connection_lost(_state, data, _error), do: reconnect_or_disconnect(data)

  defp close_options(opts, default_timeout) when is_list(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in [:mode, :timeout])) do
      validate_close_options(opts, default_timeout)
    else
      invalid_close_options(opts)
    end
  end

  defp close_options(opts, _default_timeout), do: invalid_close_options(opts)

  defp validate_close_options(opts, default_timeout) do
    mode = Keyword.get(opts, :mode, :immediate)
    timeout = Keyword.get(opts, :timeout, default_timeout)

    if mode in [:immediate, :drain] and is_integer(timeout) and timeout > 0 do
      {:ok, mode, timeout}
    else
      invalid_close_options(opts)
    end
  end

  defp invalid_close_options(opts),
    do: {:error, Error.new(:client, :close, :invalid_options, details: %{options: opts})}

  defp begin_drain(from, data, timeout) do
    if requests_idle?(data) do
      close_immediately(from, data, timeout)
    else
      token = make_ref()
      timer = Process.send_after(self(), {:drain_timeout, token}, timeout)

      drain = %{from: from, timer: timer, token: token}
      {:next_state, :draining, %{data | drain: drain}}
    end
  end

  defp close_immediately(from, data, timeout) do
    reply_closing_caller(data, :ok)
    error = Error.new(:client, :request, :connection_closed)

    data =
      data
      |> cancel_reconnect()
      |> cancel_drain()
      |> fail_all_requests(error)

    begin_disconnect(from, data, timeout)
  end

  defp reply_already_draining(from) do
    error = Error.new(:client, :close, :already_closing)
    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  defp complete_drain(data) do
    from = data.drain.from
    data = cancel_drain(data)
    begin_disconnect(from, data, data.timeout)
  end

  defp fail_drain(data, error, emit? \\ true) do
    reply_closing_caller(data, {:error, with_operation(error, :close)})
    if emit?, do: telemetry_connection_disconnected(data, error)

    data =
      data
      |> cancel_drain()
      |> fail_all_requests(error)
      |> close_socket()

    {:stop, :normal, data}
  end

  defp reply_closing_caller(%{drain: nil}, _reply), do: :ok
  defp reply_closing_caller(data, reply), do: :gen_statem.reply(data.drain.from, reply)

  defp cancel_drain(%{drain: nil} = data), do: data

  defp cancel_drain(data) do
    cancel_timer(data.drain.timer)
    %{data | drain: nil}
  end

  defp begin_disconnect(from, data, timeout) do
    if cotp_connected?(data) do
      start_cotp_disconnect(from, data, timeout)
    else
      force_close(from, data, Error.new(:client, :close, :connection_closed))
    end
  end

  defp start_cotp_disconnect(from, data, timeout) do
    request = %DisconnectRequest{
      destination_reference: data.session.remote_reference,
      source_reference: data.session.local_reference,
      reason: 0x80
    }

    with :ok <- send_cotp(data, request, :close),
         :ok <- :inet.setopts(data.socket, active: :once) do
      token = make_ref()
      timer = Process.send_after(self(), {:disconnect_timeout, token}, timeout)
      close = %{from: from, timer: timer, token: token}
      {:next_state, :disconnecting, %{data | close: close}}
    else
      {:error, %Error{} = error} -> force_close(from, data, error)
      {:error, reason} -> force_close(from, data, tcp_error(:close, reason))
    end
  end

  defp complete_disconnect(data, error) do
    reply_close_caller(data, :ok)
    telemetry_connection_disconnected(data, local_close_error(error))
    data = data |> cancel_close() |> close_socket()
    {:stop, :normal, data}
  end

  defp force_close(from, data, error) do
    telemetry_connection_disconnected(data, local_close_error(error))
    data = data |> cancel_close() |> close_socket()
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  defp local_close_error(%Error{} = outcome) do
    Error.new(:client, :close, :connection_closed,
      details: %{
        disconnect_outcome: outcome.reason,
        disconnect_layer: outcome.layer,
        disconnect_code: outcome.code
      }
    )
  end

  defp reply_close_caller(%{close: nil}, _reply), do: :ok
  defp reply_close_caller(data, reply), do: :gen_statem.reply(data.close.from, reply)

  defp cancel_close(%{close: nil} = data), do: data

  defp cancel_close(data) do
    cancel_timer(data.close.timer)
    %{data | close: nil}
  end

  defp cotp_connected?(data) do
    data.socket != nil and is_integer(data.session.local_reference) and
      is_integer(data.session.remote_reference)
  end

  defp rearm_disconnect(data) do
    case :inet.setopts(data.socket, active: :once) do
      :ok -> {:keep_state, data}
      {:error, reason} -> complete_disconnect(data, tcp_error(:close, reason))
    end
  end

  defp requests_idle?(data) do
    map_size(data.pending) == 0 and data.queued_count == 0 and is_nil(data.exclusive) and
      is_nil(data.exclusive_waiter)
  end

  defp fail_all_requests(data, error) do
    Enum.each(data.pending, fn {_reference, request} ->
      finish_request(request, request_failure_reply(request, error, :sent))
    end)

    data.queue
    |> :queue.to_list()
    |> Enum.each(fn request ->
      telemetry_request_rejected(request, data, error.reason)
      finish_request(request, request_failure_reply(request, error, :not_sent))
    end)

    data = %{
      data
      | pending: %{},
        queue: :queue.new(),
        queued_count: 0,
        request_index: %{}
    }

    fail_runtime_owners(data, error)
  end

  defp cancel_request(data, monitor) do
    case Map.pop(data.request_index, monitor) do
      {nil, _request_index} ->
        data

      {{:queued, request_id}, request_index} ->
        requests = :queue.to_list(data.queue)
        {cancelled, remaining} = Enum.split_with(requests, &(&1.id == request_id))
        Enum.each(cancelled, &telemetry_request_rejected(&1, data, :caller_down))

        %{
          data
          | queue: :queue.from_list(remaining),
            queued_count: Enum.count(remaining),
            request_index: request_index
        }

      {{:pending, reference}, request_index} ->
        pending =
          Map.update!(data.pending, reference, fn request ->
            %{request | from: nil, cancelled: true, batches: []}
          end)

        %{data | pending: pending, request_index: request_index}
    end
  end

  defp normalize_host(host) when is_binary(host), do: String.to_charlist(host)
  defp normalize_host(host), do: host

  defp negotiate_cotp(data) do
    request = %ConnectionRequest{
      src_tsap: data.src_tsap,
      dst_tsap: data.dst_tsap,
      tpdu_size: data.requested_tpdu_size
    }

    with :ok <- send_cotp(data, request, :connect),
         {:ok, packet, data} <- receive_tpkt(data, deadline(data.timeout), :connect),
         {:ok, confirm} <- decode_cotp(packet.payload, :connect),
         :ok <- validate_confirm(confirm, request) do
      tpdu_size = min(data.requested_tpdu_size, confirm.tpdu_size || data.requested_tpdu_size)

      session = %{
        data.session
        | local_reference: request.source_reference,
          remote_reference: confirm.source_reference
      }

      {:ok,
       %{
         data
         | tpdu_size: tpdu_size,
           session: session
       }}
    else
      {:error, %Error{} = error, data} -> {:error, error, data}
      {:error, %Error{} = error} -> {:error, error, data}
    end
  end

  defp validate_confirm(%ConnectionConfirm{} = confirm, request) do
    cond do
      confirm.destination_reference != request.source_reference ->
        {:error,
         Error.new(:cotp, :connect, :invalid_connection_reference,
           details: %{
             expected: request.source_reference,
             received: confirm.destination_reference
           }
         )}

      confirm.class_option != 0 ->
        {:error,
         Error.new(:cotp, :connect, :unsupported_connection_class, code: confirm.class_option)}

      true ->
        :ok
    end
  end

  defp validate_confirm(_tpdu, _request),
    do: {:error, Error.new(:cotp, :connect, :unexpected_tpdu)}

  defp negotiate_s7(data, reference) do
    request = SetupCommunication.request(data.requested_setup, reference)

    with :ok <- ensure_pdu_size(request, data, :setup_communication),
         :ok <- send_pdu(data, request, :setup_communication),
         {:ok, response, data} <- receive_pdu(data, :setup_communication),
         {:ok, setup} <- SetupCommunication.decode_response(response, reference) do
      pdu_size = min(data.requested_setup.pdu_length, setup.pdu_length)

      max_jobs =
        Enum.min([
          data.requested_setup.max_amq_calling,
          data.requested_setup.max_amq_called,
          setup.max_amq_calling,
          setup.max_amq_called
        ])

      {:ok,
       %{
         data
         | pdu_size: pdu_size,
           max_jobs: max_jobs,
           negotiated_setup: setup
       }}
    else
      {:error, %Error{} = error, data} -> {:error, error, data}
      {:error, %Error{} = error} -> {:error, error, data}
    end
  end

  defp begin_exclusive(from, operation, opts, data) do
    with :ok <- validate_transaction_identity(operation, opts),
         :ok <- ensure_transaction_available(data),
         {:ok, exclusive} <- build_exclusive(from, operation, opts, data.timeout) do
      data = %{data | exclusive_waiter: exclusive}

      case schedule_requests(data) do
        {:ok, data} -> {:keep_state, data}
        {:disconnect, error, data} -> disconnect_with_error(:ready, data, error)
      end
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp validate_transaction_identity(operation, opts)
       when is_atom(operation) and is_list(opts) do
    if Keyword.keyword?(opts) do
      :ok
    else
      transaction_error(operation, :invalid_options, %{options: opts})
    end
  end

  defp validate_transaction_identity(operation, opts) do
    operation = if is_atom(operation), do: operation, else: :transaction
    transaction_error(operation, :invalid_options, %{options: opts})
  end

  defp ensure_transaction_available(%{exclusive: nil, exclusive_waiter: nil}), do: :ok

  defp ensure_transaction_available(data) do
    operation =
      case data.exclusive || data.exclusive_waiter do
        %Exclusive{operation: operation} -> operation
        _other -> :transaction
      end

    transaction_error(operation, :transaction_busy)
  end

  defp build_exclusive({owner, _tag} = from, operation, opts, default_step_timeout) do
    allowed = [:timeout, :step_timeout, :maximum_messages, :maximum_bytes, :inbox_limit]

    with :ok <- validate_option_keys(opts, allowed, operation),
         {:ok, timeout} <-
           transaction_option(opts, :timeout, @default_transaction_timeout, operation),
         {:ok, step_timeout} <-
           transaction_option(opts, :step_timeout, default_step_timeout, operation),
         {:ok, maximum_messages} <-
           transaction_option(
             opts,
             :maximum_messages,
             @default_transaction_message_limit,
             operation
           ),
         {:ok, maximum_bytes} <-
           transaction_option(opts, :maximum_bytes, @default_transaction_byte_limit, operation),
         {:ok, inbox_limit} <-
           transaction_option(opts, :inbox_limit, @default_transaction_inbox_limit, operation) do
      token = make_ref()
      timer_token = make_ref()
      timer = Process.send_after(self(), {:transaction_timeout, timer_token}, timeout)

      {:ok,
       %Exclusive{
         token: token,
         owner: owner,
         monitor: Process.monitor(owner),
         from: from,
         operation: operation,
         timer: timer,
         timer_token: timer_token,
         step_timeout: step_timeout,
         maximum_messages: maximum_messages,
         maximum_bytes: maximum_bytes,
         inbox_limit: inbox_limit,
         inbox: :queue.new()
       }}
    end
  end

  defp validate_option_keys(opts, allowed, operation) do
    case Enum.find(Keyword.keys(opts), &(&1 not in allowed)) do
      nil -> :ok
      option -> transaction_error(operation, :invalid_option, %{option: option})
    end
  end

  defp transaction_option(opts, key, default, operation) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      transaction_error(operation, :invalid_option, %{option: key, value: value})
    end
  end

  defp submit_transaction_request(from, token, pdu, state, data) do
    with {:ok, exclusive} <- fetch_exclusive(data, from, token),
         :ok <- ensure_transaction_idle(data, exclusive.operation),
         :ok <- validate_transaction_request_pdu(pdu, exclusive.operation) do
      request =
        from
        |> new_request(:transaction, exclusive.operation, [[pdu]])
        |> monitor_request()

      data
      |> dispatch_request(request)
      |> finish_transaction_dispatch(state)
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp finish_transaction_dispatch({:ok, data}, _state), do: {:keep_state, data}

  defp finish_transaction_dispatch({:error, %Error{} = error, request, data}, state) do
    finish_request(request, {:error, error})

    if error.reason == :transaction_limit_exceeded,
      do: disconnect_with_error(state, data, error),
      else: {:keep_state, data}
  end

  defp finish_transaction_dispatch({:disconnect, %Error{} = error, request, data}, state) do
    finish_request(request, {:error, error})
    disconnect_with_error(state, data, error)
  end

  defp validate_transaction_request_pdu(%PDU{header: %{rosctr: rosctr}}, _operation)
       when rosctr in [:job, :userdata],
       do: :ok

  defp validate_transaction_request_pdu(pdu, operation),
    do: transaction_error(operation, :invalid_transaction_pdu, %{rosctr: pdu.header.rosctr})

  defp receive_transaction_job(from, token, timeout, data) do
    with {:ok, exclusive} <- fetch_exclusive(data, from, token),
         :ok <- validate_wait_timeout(timeout, exclusive.operation) do
      finish_transaction_receive(from, timeout, data, exclusive)
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp finish_transaction_receive(
         from,
         _timeout,
         data,
         %Exclusive{inbox_count: count} = exclusive
       )
       when count > 0 do
    {{:value, pdu}, inbox} = :queue.out(exclusive.inbox)
    exclusive = %{exclusive | inbox: inbox, inbox_count: count - 1}
    {:keep_state, %{data | exclusive: exclusive}, [{:reply, from, {:ok, pdu}}]}
  end

  defp finish_transaction_receive(from, _timeout, data, %Exclusive{receive_from: waiter})
       when not is_nil(waiter) do
    error = Error.new(:client, data.exclusive.operation, :transaction_receive_pending)
    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  defp finish_transaction_receive(from, timeout, data, exclusive) do
    token = make_ref()
    timer = Process.send_after(self(), {:transaction_receive_timeout, token}, timeout)

    exclusive = %{
      exclusive
      | receive_from: from,
        receive_timer: timer,
        receive_token: token
    }

    {:keep_state, %{data | exclusive: exclusive}}
  end

  defp reply_transaction_job(from, token, pdu, state, data) do
    with {:ok, exclusive} <- fetch_exclusive(data, from, token),
         :ok <- validate_transaction_reply_pdu(pdu, exclusive.operation),
         :ok <- ensure_pdu_size(pdu, data, exclusive.operation),
         {:ok, data} <- account_exclusive_pdu(data, pdu),
         :ok <- send_pdu(data, pdu, exclusive.operation) do
      {:keep_state, data, [{:reply, from, :ok}]}
    else
      {:error, %Error{} = error} ->
        if error.reason == :transaction_limit_exceeded do
          :gen_statem.reply(from, {:error, error})
          disconnect_with_error(state, data, error)
        else
          {:keep_state_and_data, [{:reply, from, {:error, error}}]}
        end
    end
  end

  defp validate_transaction_reply_pdu(%PDU{header: %{rosctr: rosctr}}, _operation)
       when rosctr in [:ack, :ack_data],
       do: :ok

  defp validate_transaction_reply_pdu(pdu, operation),
    do: transaction_error(operation, :invalid_transaction_pdu, %{rosctr: pdu.header.rosctr})

  defp finish_exclusive(from, token, state, data) do
    with {:ok, exclusive} <- fetch_exclusive(data, from, token),
         :ok <- ensure_transaction_idle(data, exclusive.operation),
         :ok <- ensure_transaction_consumed(exclusive) do
      data = clear_exclusive(data)

      case schedule_requests(data) do
        {:ok, data} -> finish_exclusive_reply(from, state, data)
        {:disconnect, error, data} -> disconnect_with_error(state, data, error)
      end
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp abort_exclusive(from, token, error, state, data) do
    with {:ok, exclusive} <- fetch_exclusive(data, from, token),
         :ok <- ensure_transaction_idle(data, exclusive.operation) do
      :gen_statem.reply(from, :ok)
      disconnect_with_error(state, data, with_operation(error, exclusive.operation))
    else
      {:error, %Error{} = transaction_error} ->
        {:keep_state_and_data, [{:reply, from, {:error, transaction_error}}]}
    end
  end

  defp fetch_exclusive(%{exclusive: %Exclusive{} = exclusive}, {owner, _tag}, token)
       when exclusive.token == token and exclusive.owner == owner,
       do: {:ok, exclusive}

  defp fetch_exclusive(data, _from, _token) do
    operation = if data.exclusive, do: data.exclusive.operation, else: :transaction
    transaction_error(operation, :invalid_transaction)
  end

  defp ensure_transaction_idle(data, _operation) when map_size(data.pending) == 0, do: :ok

  defp ensure_transaction_idle(_data, operation),
    do: transaction_error(operation, :transaction_step_pending)

  defp ensure_transaction_consumed(%Exclusive{receive_from: nil, inbox_count: 0}), do: :ok

  defp ensure_transaction_consumed(exclusive),
    do:
      transaction_error(exclusive.operation, :transaction_incomplete, %{
        inbox_count: exclusive.inbox_count,
        receive_pending: not is_nil(exclusive.receive_from)
      })

  defp validate_wait_timeout(timeout, _operation) when is_integer(timeout) and timeout > 0,
    do: :ok

  defp validate_wait_timeout(timeout, operation),
    do: transaction_error(operation, :invalid_timeout, %{timeout: timeout})

  defp enqueue_transaction_job(data, pdu) do
    case account_exclusive_pdu(data, pdu) do
      {:ok, data} -> enqueue_accounted_transaction_job(data, pdu)
      {:error, %Error{} = error} -> {:error, error, data}
    end
  end

  defp enqueue_accounted_transaction_job(data, pdu) do
    exclusive = data.exclusive

    cond do
      exclusive.receive_from ->
        :gen_statem.reply(exclusive.receive_from, {:ok, pdu})
        {:ok, %{data | exclusive: clear_transaction_receiver(exclusive)}}

      exclusive.inbox_count < exclusive.inbox_limit ->
        exclusive = %{
          exclusive
          | inbox: :queue.in(pdu, exclusive.inbox),
            inbox_count: exclusive.inbox_count + 1
        }

        {:ok, %{data | exclusive: exclusive}}

      true ->
        error =
          Error.new(:s7, exclusive.operation, :transaction_inbox_overflow,
            details: %{limit: exclusive.inbox_limit}
          )

        {:error, error, data}
    end
  end

  defp account_transaction_pdu(data, %Request{kind: :transaction}, pdu),
    do: account_exclusive_pdu(data, pdu)

  defp account_transaction_pdu(data, _request, _pdu), do: {:ok, data}

  defp account_incoming_transaction_pdu(%{exclusive: %Exclusive{}} = data, pdu),
    do: account_exclusive_pdu(data, pdu)

  defp account_incoming_transaction_pdu(data, _pdu), do: {:ok, data}

  defp account_exclusive_pdu(%{exclusive: %Exclusive{} = exclusive} = data, pdu) do
    message_count = exclusive.message_count + 1
    byte_count = exclusive.byte_count + PDU.encoded_size(pdu)

    if message_count <= exclusive.maximum_messages and byte_count <= exclusive.maximum_bytes do
      exclusive = %{exclusive | message_count: message_count, byte_count: byte_count}
      {:ok, %{data | exclusive: exclusive}}
    else
      error =
        Error.new(:s7, exclusive.operation, :transaction_limit_exceeded,
          details: %{
            message_count: message_count,
            maximum_messages: exclusive.maximum_messages,
            byte_count: byte_count,
            maximum_bytes: exclusive.maximum_bytes
          }
        )

      {:error, error}
    end
  end

  defp clear_transaction_receiver(exclusive) do
    cancel_timer(exclusive.receive_timer)

    %{
      exclusive
      | receive_from: nil,
        receive_timer: nil,
        receive_token: nil
    }
  end

  defp clear_exclusive(%{exclusive: nil} = data), do: data

  defp clear_exclusive(data) do
    exclusive = data.exclusive
    cancel_timer(exclusive.timer)
    cancel_timer(exclusive.receive_timer)
    Process.demonitor(exclusive.monitor, [:flush])
    %{data | exclusive: nil}
  end

  defp clear_exclusive_waiter(%{exclusive_waiter: nil} = data), do: data

  defp clear_exclusive_waiter(data) do
    exclusive = data.exclusive_waiter
    cancel_timer(exclusive.timer)
    Process.demonitor(exclusive.monitor, [:flush])
    %{data | exclusive_waiter: nil}
  end

  defp finish_exclusive_reply(from, state, data) do
    :gen_statem.reply(from, :ok)
    after_owner_cleanup(state, data)
  end

  defp subscribe_userdata_owner(from, filter, opts, data) do
    with {:ok, filter} <- validate_subscription_filter(filter),
         {:ok, subscription_options} <- validate_subscription_options(opts),
         :ok <- ensure_subscription_capacity(data) do
      {owner, _tag} = from
      reference = make_ref()
      monitor = Process.monitor(owner)

      subscription = %Subscription{
        reference: reference,
        owner: owner,
        monitor: monitor,
        filter: filter,
        queue: :queue.new(),
        queue_limit: subscription_options.queue_limit,
        session_bound: subscription_options.session_bound,
        owner_down_operation: subscription_options.owner_down_operation
      }

      registry = data.subscription_registry

      registry = %{
        registry
        | entries: Map.put(registry.entries, reference, subscription),
          monitor_index: Map.put(registry.monitor_index, monitor, reference)
      }

      data = %{data | subscription_registry: registry}

      {:keep_state, data, [{:reply, from, {:ok, reference}}]}
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp validate_subscription_filter(filter) when is_map(filter) do
    allowed = [:function_group, :subfunction, :sequence, :type]

    with nil <- Enum.find(Map.keys(filter), &(&1 not in allowed)),
         :ok <- validate_subscription_group(Map.get(filter, :function_group, :any)),
         :ok <- validate_subscription_subfunction(Map.get(filter, :subfunction, :any)),
         :ok <- validate_subscription_sequence(Map.get(filter, :sequence, :any)),
         :ok <- validate_subscription_type(Map.get(filter, :type, :any)) do
      {:ok,
       %{
         function_group: Map.get(filter, :function_group, :any),
         subfunction: Map.get(filter, :subfunction, :any),
         sequence: Map.get(filter, :sequence, :any),
         type: Map.get(filter, :type, :any)
       }}
    else
      option when is_atom(option) ->
        subscription_error(:subscribe_userdata, :invalid_filter, %{option: option})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_subscription_filter(filter),
    do: subscription_error(:subscribe_userdata, :invalid_filter, %{filter: filter})

  defp validate_subscription_group(group)
       when group in [
              :any,
              :programmer,
              :cyclic,
              :blocks,
              :cpu,
              :security,
              :bsend,
              :time,
              :data_record_routing,
              :nc_programming
            ],
       do: :ok

  defp validate_subscription_group(group) when group in 0..0x3F, do: :ok

  defp validate_subscription_group(group),
    do: subscription_error(:subscribe_userdata, :invalid_filter, %{function_group: group})

  defp validate_subscription_subfunction(:any), do: :ok
  defp validate_subscription_subfunction(value) when value in 0..0xFF, do: :ok

  defp validate_subscription_subfunction({:one_of, values}) when is_list(values) do
    if values != [] and Enum.count_until(values, 0x101) <= 0x100 and
         Enum.all?(values, &(&1 in 0..0xFF)) and
         Enum.uniq(values) == values do
      :ok
    else
      subscription_error(:subscribe_userdata, :invalid_filter, %{subfunction: {:one_of, values}})
    end
  end

  defp validate_subscription_subfunction(value),
    do: subscription_error(:subscribe_userdata, :invalid_filter, %{subfunction: value})

  defp validate_subscription_sequence(:any), do: :ok
  defp validate_subscription_sequence(value) when value in 0..0xFF, do: :ok

  defp validate_subscription_sequence(value),
    do: subscription_error(:subscribe_userdata, :invalid_filter, %{sequence: value})

  defp validate_subscription_type(type) when type in [:any, :indication, :request, :response],
    do: :ok

  defp validate_subscription_type(type),
    do: subscription_error(:subscribe_userdata, :invalid_filter, %{type: type})

  defp validate_subscription_options(opts) when is_list(opts) do
    allowed = [:queue_limit, :session_bound, :owner_down_operation]

    with true <- Keyword.keyword?(opts),
         nil <- Enum.find(Keyword.keys(opts), &(&1 not in allowed)),
         {:ok, queue_limit} <-
           validate_positive_subscription_option(
             opts,
             :queue_limit,
             @default_subscription_queue_limit
           ),
         {:ok, session_bound} <-
           validate_boolean_subscription_option(opts, :session_bound, false),
         {:ok, owner_down_operation} <- validate_owner_down_operation(opts) do
      {:ok,
       %{
         queue_limit: queue_limit,
         session_bound: session_bound,
         owner_down_operation: owner_down_operation
       }}
    else
      false ->
        subscription_error(:subscribe_userdata, :invalid_options, %{options: opts})

      option when is_atom(option) ->
        subscription_error(:subscribe_userdata, :invalid_option, %{
          option: option,
          value: Keyword.get(opts, option)
        })

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp validate_subscription_options(opts),
    do: subscription_error(:subscribe_userdata, :invalid_options, %{options: opts})

  defp validate_positive_subscription_option(opts, option, default) do
    value = Keyword.get(opts, option, default)

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else:
        subscription_error(:subscribe_userdata, :invalid_option, %{option: option, value: value})
  end

  defp validate_boolean_subscription_option(opts, option, default) do
    value = Keyword.get(opts, option, default)

    if is_boolean(value),
      do: {:ok, value},
      else:
        subscription_error(:subscribe_userdata, :invalid_option, %{option: option, value: value})
  end

  defp validate_owner_down_operation(opts) do
    operation = Keyword.get(opts, :owner_down_operation, :userdata_subscription)

    if is_atom(operation),
      do: {:ok, operation},
      else:
        subscription_error(:subscribe_userdata, :invalid_option, %{
          option: :owner_down_operation,
          value: operation
        })
  end

  defp ensure_subscription_capacity(data) do
    registry = data.subscription_registry

    if map_size(registry.entries) < registry.limit do
      :ok
    else
      subscription_error(:subscribe_userdata, :subscription_limit, %{
        limit: registry.limit
      })
    end
  end

  defp next_userdata_event(from, reference, timeout, data) do
    with {:ok, subscription} <- fetch_subscription(data, reference, from),
         :ok <- validate_wait_timeout(timeout, :next_userdata) do
      finish_next_userdata(from, timeout, data, subscription)
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp finish_next_userdata(from, _timeout, _data, %Subscription{error: %Error{} = error}),
    do: {:keep_state_and_data, [{:reply, from, {:error, error}}]}

  defp finish_next_userdata(
         from,
         _timeout,
         data,
         %Subscription{queued_count: count} = subscription
       )
       when count > 0 do
    {{:value, message}, queue} = :queue.out(subscription.queue)
    subscription = %{subscription | queue: queue, queued_count: count - 1}
    data = put_subscription(data, subscription)
    {:keep_state, data, [{:reply, from, {:ok, message}}]}
  end

  defp finish_next_userdata(from, _timeout, _data, %Subscription{waiter: waiter})
       when not is_nil(waiter) do
    error = Error.new(:client, :next_userdata, :subscription_receive_pending)
    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  defp finish_next_userdata(from, timeout, data, subscription) do
    token = make_ref()

    timer =
      Process.send_after(self(), {:subscription_timeout, subscription.reference, token}, timeout)

    subscription = %{subscription | waiter: from, timer: timer, timer_token: token}
    {:keep_state, put_subscription(data, subscription)}
  end

  defp rebind_userdata_subscription_owner(from, reference, filter, data) do
    with {:ok, filter} <- validate_subscription_filter(filter),
         {:ok, subscription} <- fetch_subscription(data, reference, from) do
      subscription = rebind_subscription(subscription, filter)
      data = put_subscription(data, subscription)

      reply =
        case subscription.error do
          nil -> :ok
          %Error{} = error -> {:error, error}
        end

      {:keep_state, data, [{:reply, from, reply}]}
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp rebind_subscription(subscription, filter) do
    messages =
      subscription.queue
      |> :queue.to_list()
      |> Enum.filter(fn message ->
        subscription_matches?(%{subscription | filter: filter}, message)
      end)

    %{
      subscription
      | filter: filter,
        queue: :queue.from_list(messages),
        queued_count: length(messages)
    }
  end

  defp validate_userdata_subscription_owner(from, reference, data) do
    reply =
      case fetch_subscription(data, reference, from) do
        {:ok, _subscription} -> :ok
        {:error, %Error{} = error} -> {:error, error}
      end

    {:keep_state_and_data, [{:reply, from, reply}]}
  end

  defp unsubscribe_userdata_owner(from, reference, data) do
    case fetch_subscription(data, reference, from) do
      {:ok, subscription} ->
        data = remove_subscription(data, subscription)
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp fetch_subscription(data, reference, {owner, _tag}) do
    case Map.get(data.subscription_registry.entries, reference) do
      %Subscription{owner: ^owner} = subscription -> {:ok, subscription}
      _other -> subscription_error(:next_userdata, :invalid_subscription)
    end
  end

  defp timeout_subscription(reference, token, data) do
    case Map.get(data.subscription_registry.entries, reference) do
      %Subscription{timer_token: ^token} = subscription ->
        error = Error.new(:client, :next_userdata, :timeout)
        :gen_statem.reply(subscription.waiter, {:error, error})
        subscription = clear_subscription_waiter(subscription)
        {:keep_state, put_subscription(data, subscription)}

      _other ->
        :keep_state_and_data
    end
  end

  defp route_userdata_indication(data, message, pdu) do
    {data, matches} =
      Enum.reduce(data.subscription_registry.entries, {data, 0}, fn
        {_reference, subscription}, {data, matches} ->
          if subscription_matches?(subscription, message) do
            {deliver_subscription(data, subscription, message), matches + 1}
          else
            {data, matches}
          end
      end)

    if matches == 0, do: telemetry_unhandled_userdata(message, pdu)
    {data, matches}
  end

  defp handle_userdata_indication(message, pdu, pdus, data) do
    {data, matches} = route_userdata_indication(data, message, pdu)
    continue_userdata_indication(matches, pdu, pdus, data)
  end

  defp continue_userdata_indication(matches, _pdu, pdus, data) when matches > 0,
    do: handle_received_pdus(pdus, data)

  defp continue_userdata_indication(0, pdu, pdus, data) do
    case account_incoming_transaction_pdu(data, pdu) do
      {:ok, data} -> handle_received_pdus(pdus, data)
      {:error, %Error{} = error} -> {:disconnect, error, data}
    end
  end

  defp subscription_matches?(%Subscription{filter: filter}, message) do
    parameter = message.parameter

    filter_match?(filter.function_group, parameter.function_group) and
      filter_match?(filter.subfunction, parameter.subfunction) and
      filter_match?(filter.sequence, parameter.sequence) and
      filter_match?(filter.type, parameter.type)
  end

  defp filter_match?(:any, _value), do: true
  defp filter_match?({:one_of, values}, value), do: value in values
  defp filter_match?(expected, value), do: expected == value

  defp deliver_subscription(data, %Subscription{error: %Error{}} = subscription, _message),
    do: put_subscription(data, subscription)

  defp deliver_subscription(data, %Subscription{waiter: waiter} = subscription, message)
       when not is_nil(waiter) do
    :gen_statem.reply(waiter, {:ok, message})
    put_subscription(data, clear_subscription_waiter(subscription))
  end

  defp deliver_subscription(
         data,
         %Subscription{queued_count: count, queue_limit: limit} = subscription,
         message
       )
       when count < limit do
    subscription = %{
      subscription
      | queue: :queue.in(message, subscription.queue),
        queued_count: count + 1
    }

    put_subscription(data, subscription)
  end

  defp deliver_subscription(data, subscription, _message) do
    error =
      Error.new(:client, :next_userdata, :subscription_overflow,
        details: %{limit: subscription.queue_limit}
      )

    subscription = %{
      subscription
      | error: error,
        queue: :queue.new(),
        queued_count: 0
    }

    put_subscription(data, subscription)
  end

  defp put_subscription(data, subscription) do
    registry = data.subscription_registry
    entries = Map.put(registry.entries, subscription.reference, subscription)
    %{data | subscription_registry: %{registry | entries: entries}}
  end

  defp clear_subscription_waiter(subscription) do
    cancel_timer(subscription.timer)
    %{subscription | waiter: nil, timer: nil, timer_token: nil}
  end

  defp remove_subscription(data, subscription) do
    subscription = clear_subscription_waiter(subscription)
    Process.demonitor(subscription.monitor, [:flush])

    registry = data.subscription_registry

    registry = %{
      registry
      | entries: Map.delete(registry.entries, subscription.reference),
        monitor_index: Map.delete(registry.monitor_index, subscription.monitor)
    }

    %{data | subscription_registry: registry}
  end

  defp fail_runtime_owners(data, error) do
    data = fail_exclusive_owner(data, error)

    Enum.each(data.subscription_registry.entries, fn {_reference, subscription} ->
      if subscription.waiter do
        :gen_statem.reply(
          subscription.waiter,
          {:error, with_operation(error, :next_userdata)}
        )
      end

      cancel_timer(subscription.timer)
      Process.demonitor(subscription.monitor, [:flush])
    end)

    registry = %{data.subscription_registry | entries: %{}, monitor_index: %{}}
    %{data | subscription_registry: registry}
  end

  defp fail_exclusive_owner(data, error) do
    if data.exclusive && data.exclusive.receive_from do
      :gen_statem.reply(
        data.exclusive.receive_from,
        {:error, with_operation(error, data.exclusive.operation)}
      )
    end

    if data.exclusive_waiter do
      :gen_statem.reply(
        data.exclusive_waiter.from,
        {:error, with_operation(error, data.exclusive_waiter.operation)}
      )
    end

    data |> clear_exclusive() |> clear_exclusive_waiter()
  end

  defp handle_owner_down(%{exclusive: %Exclusive{monitor: monitor} = exclusive} = data, monitor) do
    error = Error.new(:client, exclusive.operation, :transaction_owner_down)
    {:exclusive, error, data}
  end

  defp handle_owner_down(
         %{exclusive_waiter: %Exclusive{monitor: monitor}} = data,
         monitor
       ),
       do: {:ok, clear_exclusive_waiter(data)}

  defp handle_owner_down(data, monitor) do
    registry = data.subscription_registry

    case Map.pop(registry.monitor_index, monitor) do
      {nil, _index} ->
        {:ok, cancel_request(data, monitor)}

      {reference, index} ->
        remove_owner_subscription(data, registry, reference, index)
    end
  end

  defp remove_owner_subscription(data, registry, reference, index) do
    case Map.pop(registry.entries, reference) do
      {nil, _subscriptions} ->
        registry = %{registry | monitor_index: index}
        {:ok, %{data | subscription_registry: registry}}

      {%Subscription{} = subscription, subscriptions} ->
        cancel_timer(subscription.timer)
        registry = %{registry | entries: subscriptions, monitor_index: index}
        finish_owner_subscription(%{data | subscription_registry: registry}, subscription)
    end
  end

  defp finish_owner_subscription(
         data,
         %Subscription{session_bound: true, owner_down_operation: operation}
       ) do
    error = Error.new(:client, operation, :subscription_owner_down)
    {:session_bound, error, data}
  end

  defp finish_owner_subscription(data, %Subscription{}), do: {:ok, data}

  defp continue_after_owner_down(state, data) do
    case schedule_requests(data) do
      {:ok, data} -> after_owner_cleanup(state, data)
      {:disconnect, error, data} -> disconnect_with_error(state, data, error)
    end
  end

  defp after_owner_cleanup(:draining, data) do
    if requests_idle?(data), do: complete_drain(data), else: {:keep_state, data}
  end

  defp after_owner_cleanup(_state, data), do: {:keep_state, data}

  defp subscription_error(operation, reason, details \\ %{}),
    do: {:error, Error.new(:client, operation, reason, details: details)}

  defp transaction_error(operation, reason, details \\ %{}),
    do: {:error, Error.new(:client, operation, reason, details: details)}

  defp submit_request(from, operation, data) do
    with {:ok, request} <- build_request(from, operation, data),
         :ok <- admit_request(data, request) do
      request = monitor_request(request)
      data = enqueue_request(data, request)

      case schedule_requests(data) do
        {:ok, data} -> {:keep_state, data}
        {:disconnect, error, data} -> disconnect_with_error(:ready, data, error)
      end
    else
      {:error, %Error{} = error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  defp build_request(from, {:read, address, raw?}, data) do
    with {:ok, batches} <- plan_read([address], data) do
      {:ok, new_request(from, :read, :read, batches, raw?)}
    end
  end

  defp build_request(from, {:read_many, addresses, raw?}, data) do
    with {:ok, batches} <- plan_read(addresses, data) do
      {:ok, new_request(from, :read_many, :read_many, batches, raw?)}
    end
  end

  defp build_request(from, {:write, address, value}, data) do
    with {:ok, batches} <- plan_write([{address, value}], data) do
      {:ok, new_request(from, :write, :write, batches)}
    end
  end

  defp build_request(from, {:write_many, items}, data) do
    with {:ok, batches} <- plan_write(items, data) do
      {:ok, new_request(from, :write_many, :write_many, batches)}
    end
  end

  defp build_request(from, {:userdata, %UserData{} = message, operation}, _data)
       when is_atom(operation) do
    case UserData.validate(message) do
      :ok -> {:ok, new_request(from, :userdata, operation, [[message]])}
      {:error, reason} -> {:error, Error.new(:s7, operation, reason)}
    end
  end

  defp build_request(_from, {:userdata, _message, operation}, _data) do
    operation = if is_atom(operation), do: operation, else: :userdata
    {:error, Error.new(:s7, operation, :invalid_userdata)}
  end

  defp build_request(from, {:read_szl, id, index, limits, operation}, _data)
       when is_atom(operation) do
    case SZLProtocol.start(id, index, limits) do
      {:ok, message, transaction} ->
        request = new_request(from, :szl, operation, [[message]])
        {:ok, %{request | context: transaction}}

      {:error, %Error{} = error} ->
        {:error, %{error | operation: operation}}
    end
  end

  defp build_request(_from, {:read_szl, _id, _index, _limits, _operation}, _data),
    do: {:error, Error.new(:client, :read_szl, :invalid_szl_request)}

  defp build_request(from, {:blocks, :counts}, _data) do
    build_blocks_request(from, BlocksProtocol.start_counts(), :block_counts)
  end

  defp build_request(from, {:blocks, :list, type, limits}, _data) do
    build_blocks_request(from, BlocksProtocol.start_list(type, limits), :list_blocks)
  end

  defp build_request(from, {:blocks, :info, block}, _data) do
    build_blocks_request(from, BlocksProtocol.start_info(block), :block_info)
  end

  defp build_request(from, {:clock, :read}, _data) do
    build_userdata_service_request(from, ClockProtocol.read_request(), :clock, :read_clock, :read)
  end

  defp build_request(from, {:clock, :set, datetime}, _data) do
    build_userdata_service_request(
      from,
      ClockProtocol.set_request(datetime),
      :clock,
      :set_clock,
      :set
    )
  end

  defp build_request(from, {:security, :login, password}, _data) do
    build_userdata_service_request(
      from,
      SecurityProtocol.login_request(password),
      :security,
      :authenticate,
      :login
    )
  end

  defp build_request(from, {:security, :logout}, _data) do
    build_userdata_service_request(
      from,
      SecurityProtocol.logout_request(),
      :security,
      :logout,
      :logout
    )
  end

  defp build_blocks_request(from, result, operation) do
    case result do
      {:ok, message, transaction} ->
        request = new_request(from, :blocks, operation, [[message]])
        {:ok, %{request | context: transaction}}

      {:error, %Error{} = error} ->
        {:error, %{error | operation: operation}}
    end
  end

  defp build_userdata_service_request(from, result, kind, operation, action) do
    case result do
      {:ok, message} ->
        request = new_request(from, kind, operation, [[message]])
        {:ok, %{request | context: action}}

      {:error, %Error{} = error} ->
        {:error, %{error | operation: operation}}
    end
  end

  defp plan_read(addresses, data) do
    PDUPlanner.plan_read(addresses, data.pdu_size, maximum_items: data.max_items_per_pdu)
  end

  defp plan_write(items, data) do
    PDUPlanner.plan_write(items, data.pdu_size, maximum_items: data.max_items_per_pdu)
  end

  defp new_request(from, kind, operation, batches, raw? \\ nil) do
    %Request{
      id: make_ref(),
      from: from,
      monitor: nil,
      kind: kind,
      operation: operation,
      batches: batches,
      raw?: raw?,
      enqueued_at: Telemetry.monotonic_time()
    }
  end

  defp admit_request(data, request) do
    if data.queued_count >= data.max_queue_size and
         not request_dispatchable_now?(data, request) do
      telemetry_request_rejected(request, data, :queue_full)

      {:error,
       Error.new(:client, request.operation, :queue_full, details: %{limit: data.max_queue_size})}
    else
      :ok
    end
  end

  defp request_dispatchable_now?(%{exclusive: %Exclusive{}}, _request), do: false
  defp request_dispatchable_now?(%{exclusive_waiter: %Exclusive{}}, _request), do: false

  defp request_dispatchable_now?(data, request) do
    data.queued_count == 0 and map_size(data.pending) < data.max_jobs and
      not security_pending?(data) and
      (request.kind != :security or map_size(data.pending) == 0)
  end

  defp monitor_request(%Request{from: {pid, _tag}} = request) do
    %{request | monitor: Process.monitor(pid)}
  end

  defp enqueue_request(data, request) do
    queue = :queue.in(request, data.queue)
    finish_enqueue(data, request, queue)
  end

  defp enqueue_priority_request(data, request) do
    queue = :queue.in_r(request, data.queue)
    finish_enqueue(data, request, queue)
  end

  defp finish_enqueue(data, request, queue) do
    request_index = Map.put(data.request_index, request.monitor, {:queued, request.id})

    data = %{
      data
      | queue: queue,
        queued_count: data.queued_count + 1,
        request_index: request_index
    }

    telemetry_request_queued(request, data)
    data
  end

  defp schedule_requests(%{exclusive: %Exclusive{}} = data), do: {:ok, data}

  defp schedule_requests(%{exclusive_waiter: %Exclusive{} = exclusive, pending: pending} = data)
       when map_size(pending) == 0 do
    if Process.alive?(exclusive.owner) do
      :gen_statem.reply(exclusive.from, {:ok, exclusive.token})
      exclusive = %{exclusive | from: nil}
      {:ok, %{data | exclusive: exclusive, exclusive_waiter: nil}}
    else
      data |> clear_exclusive_waiter() |> schedule_requests()
    end
  end

  defp schedule_requests(%{exclusive_waiter: %Exclusive{}} = data), do: {:ok, data}

  defp schedule_requests(data) do
    if security_pending?(data) do
      {:ok, data}
    else
      schedule_available_requests(data)
    end
  end

  defp schedule_available_requests(data)
       when map_size(data.pending) >= data.max_jobs or data.queued_count == 0,
       do: {:ok, data}

  defp schedule_available_requests(data) do
    {:value, request} = :queue.peek(data.queue)

    if request.kind == :security and map_size(data.pending) > 0 do
      {:ok, data}
    else
      dispatch_queued_request(data)
    end
  end

  defp dispatch_queued_request(data) do
    {{:value, request}, queue} = :queue.out(data.queue)

    data = %{
      data
      | queue: queue,
        queued_count: data.queued_count - 1,
        request_index: Map.delete(data.request_index, request.monitor)
    }

    if caller_alive?(request) do
      schedule_dispatched_request(dispatch_request(data, request))
    else
      telemetry_request_rejected(request, data, :caller_down)
      finish_request(request, nil)
      schedule_requests(data)
    end
  end

  defp security_pending?(data),
    do: Enum.any?(data.pending, fn {_reference, request} -> request.kind == :security end)

  defp schedule_dispatched_request(result) do
    case result do
      {:ok, data} ->
        schedule_requests(data)

      {:error, error, request, data} ->
        telemetry_request_rejected(request, data, error.reason)
        finish_request(request, request_failure_reply(request, error, :not_sent))
        schedule_requests(data)

      {:disconnect, error, request, data} ->
        finish_request(request, request_failure_reply(request, error, :sent))
        {:disconnect, error, data}
    end
  end

  defp dispatch_request(data, %Request{batches: [batch | batches]} = request) do
    {reference, data} = allocate_reference(data)

    request = %{
      request
      | reference: reference,
        current_batch: batch,
        batches: batches
    }

    with {:ok, pdu} <- encode_batch(request, batch, reference),
         :ok <- ensure_pdu_size(pdu, data, request.operation),
         {:ok, data} <- account_transaction_pdu(data, request, pdu) do
      request = telemetry_request_start(request, pdu, data)

      case send_pdu(data, pdu, request.operation) do
        :ok ->
          token = make_ref()
          timeout = request_timeout(data, request)
          timer = Process.send_after(self(), {:request_timeout, reference, token}, timeout)
          request = %{request | timer: timer, timer_token: token}

          pending = Map.put(data.pending, reference, request)
          request_index = Map.put(data.request_index, request.monitor, {:pending, reference})
          {:ok, %{data | pending: pending, request_index: request_index}}

        {:error, %Error{} = error} ->
          {:disconnect, error, request, data}
      end
    else
      {:error, %Error{} = error} -> {:error, error, request, data}
    end
  end

  defp encode_batch(%Request{kind: kind}, batch, reference)
       when kind in [:read, :read_many],
       do: ReadVar.request_many(batch, reference)

  defp encode_batch(%Request{kind: kind}, batch, reference)
       when kind in [:write, :write_many],
       do: WriteVar.request_many(batch, reference)

  defp encode_batch(%Request{kind: :userdata}, [%UserData{} = message], reference),
    do: UserData.to_pdu(message, reference)

  defp encode_batch(%Request{kind: :szl}, [%UserData{} = message], reference),
    do: UserData.to_pdu(message, reference)

  defp encode_batch(%Request{kind: :blocks}, [%UserData{} = message], reference),
    do: UserData.to_pdu(message, reference)

  defp encode_batch(%Request{kind: kind}, [%UserData{} = message], reference)
       when kind in [:clock, :security],
       do: UserData.to_pdu(message, reference)

  defp encode_batch(%Request{kind: :transaction}, [%PDU{} = pdu], reference) do
    {:ok, put_in(pdu.header.pdu_reference, reference)}
  end

  defp request_timeout(%{exclusive: %Exclusive{} = exclusive}, %Request{kind: :transaction}),
    do: exclusive.step_timeout

  defp request_timeout(data, _request), do: data.timeout

  defp allocate_reference(data), do: allocate_reference(data, data.reference, 0)

  defp allocate_reference(data, candidate, attempts) when attempts < 0xFFFF do
    if Map.has_key?(data.pending, candidate) do
      allocate_reference(data, next_reference(candidate), attempts + 1)
    else
      {candidate, %{data | reference: next_reference(candidate)}}
    end
  end

  defp receive_active_bytes(data, bytes) do
    opts = [
      max_tpkt_size: data.max_tpkt_size,
      maximum_fragments: cotp_fragment_limit(data),
      receive_buffer_limit: data.receive_buffer_limit,
      pdu_size: data.pdu_size,
      tpdu_size: data.tpdu_size
    ]

    case Stream.push(data.stream, bytes, opts) do
      {:ok, pdus, stream} -> handle_received_pdus(pdus, %{data | stream: stream})
      {:error, %Error{} = error} -> {:disconnect, error, data}
    end
  end

  defp handle_received_pdus([], data), do: {:ok, data}

  defp handle_received_pdus([%DisconnectRequest{} = request | _events], data) do
    with :ok <- validate_disconnect_request(request, data),
         :ok <- confirm_remote_disconnect(request, data) do
      error =
        Error.new(:cotp, :request, :remote_disconnect,
          code: request.reason,
          details: %{
            destination_reference: request.destination_reference,
            source_reference: request.source_reference,
            additional_information: request.additional_information
          }
        )

      {:disconnect, error, data}
    else
      {:error, %Error{} = error} -> {:disconnect, error, data}
    end
  end

  defp handle_received_pdus(
         [%DisconnectConfirm{} = confirm | _events],
         %{close: %{from: from}} = data
       )
       when not is_nil(from) do
    case validate_disconnect_confirm(confirm, data) do
      :ok -> {:close_confirmed, data}
      {:error, %Error{} = error} -> {:disconnect, error, data}
    end
  end

  defp handle_received_pdus([%DisconnectConfirm{} = confirm | _events], data) do
    error =
      Error.new(:cotp, :request, :unexpected_disconnect_confirm,
        details: %{
          destination_reference: confirm.destination_reference,
          source_reference: confirm.source_reference
        }
      )

    {:disconnect, error, data}
  end

  defp handle_received_pdus([%ErrorTPDU{} = tpdu | _events], data) do
    error =
      Error.new(:cotp, :request, :protocol_error,
        code: tpdu.reject_cause,
        details: %{invalid_tpdu: tpdu.invalid_tpdu}
      )

    {:disconnect, error, data}
  end

  defp handle_received_pdus(
         [%PDU{header: %{rosctr: :userdata}} = pdu | pdus],
         data
       ) do
    case UserData.from_pdu(pdu) do
      {:ok, %UserData{parameter: %{type: :indication}} = message} ->
        handle_userdata_indication(message, pdu, pdus, data)

      {:ok, _message} ->
        handle_correlatable_pdu(pdu, pdus, data)

      {:error, %Error{} = error} ->
        {:disconnect, error, data}
    end
  end

  defp handle_received_pdus(
         [%PDU{header: %{rosctr: :job}} = pdu | pdus],
         %{exclusive: %Exclusive{}} = data
       ) do
    case enqueue_transaction_job(data, pdu) do
      {:ok, data} -> handle_received_pdus(pdus, data)
      {:error, %Error{} = error, data} -> {:disconnect, error, data}
    end
  end

  defp handle_received_pdus([pdu | pdus], data),
    do: handle_correlatable_pdu(pdu, pdus, data)

  defp validate_disconnect_request(request, data) do
    validate_disconnect_references(
      request.destination_reference,
      request.source_reference,
      data,
      :request
    )
  end

  defp validate_disconnect_confirm(confirm, data) do
    validate_disconnect_references(
      confirm.destination_reference,
      confirm.source_reference,
      data,
      :close
    )
  end

  defp validate_disconnect_references(destination, source, data, operation) do
    if destination == data.session.local_reference and source == data.session.remote_reference do
      :ok
    else
      {:error,
       Error.new(:cotp, operation, :invalid_connection_reference,
         details: %{
           expected_destination: data.session.local_reference,
           received_destination: destination,
           expected_source: data.session.remote_reference,
           received_source: source
         }
       )}
    end
  end

  defp confirm_remote_disconnect(%DisconnectRequest{source_reference: 0}, _data), do: :ok

  defp confirm_remote_disconnect(request, data) do
    confirm = %DisconnectConfirm{
      destination_reference: request.source_reference,
      source_reference: request.destination_reference
    }

    send_cotp(data, confirm, :request)
  end

  defp handle_correlatable_pdu(pdu, pdus, data) do
    case account_incoming_transaction_pdu(data, pdu) do
      {:ok, data} -> correlate_accounted_pdu(pdu, pdus, data)
      {:error, %Error{} = error} -> {:disconnect, error, data}
    end
  end

  defp correlate_accounted_pdu(pdu, pdus, data) do
    reference = pdu.header.pdu_reference

    case take_pending(data, reference) do
      {:ok, request, data} ->
        handle_correlated_pdu(decode_batch_response(request, pdu), request, pdu, pdus, data)

      :error ->
        error =
          Error.new(:s7, :request, :unexpected_pdu_reference,
            details: %{received: reference, pending: Map.keys(data.pending)}
          )

        {:disconnect, error, data}
    end
  end

  defp handle_correlated_pdu({:ok, item_results}, request, pdu, pdus, data) do
    outcome = telemetry_response_outcome(request, item_results)
    request = telemetry_request_stop(request, outcome, nil, item_results, PDU.encoded_size(pdu))
    data = handle_batch_results(data, request, item_results)
    handle_received_pdus(pdus, data)
  end

  defp handle_correlated_pdu({:error, %Error{} = error}, request, pdu, pdus, data) do
    request = telemetry_request_stop(request, :error, error, [], PDU.encoded_size(pdu))
    finish_request(request, request_failure_reply(request, error, :sent))

    case response_action(error) do
      :disconnect -> {:disconnect, error, data}
      :keep -> handle_received_pdus(pdus, data)
    end
  end

  defp take_pending(data, reference) do
    case Map.pop(data.pending, reference) do
      {nil, _pending} ->
        :error

      {%Request{} = request, pending} ->
        cancel_timer(request.timer)

        data = %{
          data
          | pending: pending,
            request_index: Map.delete(data.request_index, request.monitor)
        }

        {:ok, %{request | timer: nil, timer_token: nil}, data}
    end
  end

  defp decode_batch_response(%Request{kind: kind, raw?: raw?} = request, pdu)
       when kind in [:read, :read_many] do
    decoder = if raw?, do: &ReadVar.decode_raw_responses/3, else: &ReadVar.decode_responses/3
    decoder.(pdu, request.current_batch, request.reference)
  end

  defp decode_batch_response(%Request{kind: kind} = request, pdu)
       when kind in [:write, :write_many] do
    WriteVar.decode_responses(pdu, Enum.count(request.current_batch), request.reference)
  end

  defp decode_batch_response(
         %Request{kind: :userdata, current_batch: [%UserData{} = message]} = request,
         pdu
       ) do
    case UserData.decode_response(pdu, message, request.reference) do
      {:ok, response} -> {:ok, [response]}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp decode_batch_response(
         %Request{
           kind: :blocks,
           current_batch: [%UserData{} = message],
           context: transaction
         } = request,
         pdu
       ) do
    with {:ok, response} <- UserData.decode_response(pdu, message, request.reference) do
      case BlocksProtocol.consume(response, transaction, request.operation) do
        {:ok, result} ->
          {:ok, [{:complete, result}]}

        {:continue, next_message, transaction} ->
          {:ok, [{:continue, next_message, transaction}]}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp decode_batch_response(
         %Request{kind: :clock, current_batch: [%UserData{} = message], context: action} =
           request,
         pdu
       ) do
    case ClockProtocol.decode_response(pdu, message, request.reference, action) do
      {:ok, result} -> {:ok, [{action, result}]}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp decode_batch_response(
         %Request{kind: :security, current_batch: [%UserData{} = message], context: action} =
           request,
         pdu
       ) do
    case SecurityProtocol.decode_response(pdu, message, request.reference) do
      {:ok, :ok} -> {:ok, [action]}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp decode_batch_response(
         %Request{
           kind: :szl,
           current_batch: [%UserData{} = message],
           context: transaction
         } = request,
         pdu
       ) do
    with {:ok, response} <- UserData.decode_response(pdu, message, request.reference) do
      case SZLProtocol.consume(response, transaction, request.operation) do
        {:ok, szl} ->
          {:ok, [{:complete, szl}]}

        {:continue, next_message, transaction} ->
          {:ok, [{:continue, next_message, transaction}]}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp decode_batch_response(%Request{kind: :transaction}, %PDU{} = pdu), do: {:ok, [pdu]}

  defp handle_batch_results(data, %Request{kind: :security} = request, item_results),
    do: handle_active_batch_results(data, request, item_results)

  defp handle_batch_results(data, request, item_results) do
    if caller_alive?(request) and not request.cancelled do
      handle_active_batch_results(data, request, item_results)
    else
      finish_request(request, nil)
      data
    end
  end

  defp handle_active_batch_results(data, %Request{kind: :read} = request, [result]) do
    finish_request(request, result)
    data
  end

  defp handle_active_batch_results(data, %Request{kind: :write} = request, [result]) do
    finish_request(request, result)
    data
  end

  defp handle_active_batch_results(data, %Request{kind: :userdata} = request, [response]) do
    finish_request(request, {:ok, response})
    data
  end

  defp handle_active_batch_results(data, %Request{kind: :transaction} = request, [pdu]) do
    finish_request(request, {:ok, pdu})
    data
  end

  defp handle_active_batch_results(data, %Request{kind: :clock} = request, [{:read, clock}]) do
    finish_request(request, {:ok, clock})
    data
  end

  defp handle_active_batch_results(data, %Request{kind: :clock} = request, [{:set, :ok}]) do
    finish_request(request, :ok)
    data
  end

  defp handle_active_batch_results(data, %Request{kind: :security} = request, [action])
       when action in [:login, :logout] do
    finish_request(request, :ok)
    %{data | session: %{data.session | authenticated: action == :login}}
  end

  defp handle_active_batch_results(data, %Request{kind: kind} = request, [
         {:complete, szl}
       ])
       when kind in [:szl, :blocks] do
    finish_request(request, {:ok, szl})
    data
  end

  defp handle_active_batch_results(data, %Request{kind: kind} = request, [
         {:continue, message, transaction}
       ])
       when kind in [:szl, :blocks] do
    request = %{
      request
      | reference: nil,
        current_batch: nil,
        batches: [[message]],
        context: transaction,
        enqueued_at: Telemetry.monotonic_time()
    }

    enqueue_priority_request(data, request)
  end

  defp handle_active_batch_results(data, %Request{kind: :read_many} = request, item_results) do
    results = prepend_results(read_results(request.current_batch, item_results), request.results)
    continue_or_finish(data, %{request | results: results})
  end

  defp handle_active_batch_results(data, %Request{kind: :write_many} = request, item_results) do
    results = prepend_results(write_results(request.current_batch, item_results), request.results)
    continue_or_finish(data, %{request | results: results})
  end

  defp continue_or_finish(data, %Request{batches: []} = request) do
    finish_request(request, {:ok, Enum.reverse(request.results)})
    data
  end

  defp continue_or_finish(data, request) do
    request = %{
      request
      | reference: nil,
        current_batch: nil,
        enqueued_at: Telemetry.monotonic_time()
    }

    enqueue_request(data, request)
  end

  defp request_failure_reply(%Request{kind: kind, operation: operation}, error, _send_state)
       when kind in [:read, :write, :userdata, :szl, :blocks, :clock, :security, :transaction],
       do: {:error, with_operation(error, operation)}

  defp request_failure_reply(%Request{kind: :read_many} = request, error, send_state) do
    error = with_operation(error, request.operation)
    results = failed_multi_results(request, error, send_state, :error)
    {:error, error, results}
  end

  defp request_failure_reply(%Request{kind: :write_many} = request, error, send_state) do
    error = with_operation(error, request.operation)
    results = failed_multi_results(request, error, send_state, :indeterminate)
    {:error, error, results}
  end

  defp failed_multi_results(request, error, send_state, sent_status) do
    completed = Enum.reverse(request.results)

    current =
      case {send_state, request.current_batch} do
        {:sent, batch} when is_list(batch) ->
          failed_batch(request.kind, batch, sent_status, error)

        _other ->
          []
      end

    remaining_batches =
      case {send_state, request.current_batch} do
        {:not_sent, batch} when is_list(batch) -> [batch | request.batches]
        _other -> request.batches
      end

    remaining = failed_batch(request.kind, List.flatten(remaining_batches), :not_attempted, error)
    completed ++ current ++ remaining
  end

  defp failed_batch(kind, items, status, error) when kind in [:read, :read_many],
    do: failed_results(items, status, error)

  defp failed_batch(kind, items, status, error) when kind in [:write, :write_many],
    do: failed_write_results(items, error, status)

  defp finish_request(request, reply) do
    request = stop_unfinished_request_span(request, reply)
    cancel_timer(request.timer)

    if request.monitor do
      Process.demonitor(request.monitor, [:flush])
    end

    if request.from && not request.cancelled && reply do
      :gen_statem.reply(request.from, reply)
    end

    :ok
  end

  defp telemetry_connection_connected(data, reconnected?) do
    Telemetry.execute(
      [:s7, :connection, :connected],
      %{
        system_time: System.system_time(),
        pdu_size: data.pdu_size,
        max_jobs: data.max_jobs
      },
      Map.put(connection_metadata(data), :reconnected, reconnected?)
    )
  end

  defp telemetry_connection_disconnected(%{socket: nil}, _error), do: :ok

  defp telemetry_connection_disconnected(data, %Error{} = error) do
    metadata =
      data
      |> connection_metadata()
      |> Map.merge(%{error_layer: error.layer, error_reason: error.reason})
      |> Map.merge(
        Map.take(error.details, [:disconnect_outcome, :disconnect_layer, :disconnect_code])
      )

    Telemetry.execute(
      [:s7, :connection, :disconnected],
      %{system_time: System.system_time()},
      metadata
    )
  end

  defp telemetry_unhandled_userdata(message, pdu) do
    parameter = message.parameter

    Telemetry.execute(
      [:s7, :userdata, :unhandled],
      %{system_time: System.system_time(), payload_size: byte_size(message.payload.data)},
      %{
        connection: self(),
        reference: pdu.header.pdu_reference,
        function_group: parameter.function_group,
        subfunction: parameter.subfunction,
        sequence: parameter.sequence
      }
    )
  end

  defp telemetry_reconnect_scheduled(data, delay) do
    Telemetry.execute(
      [:s7, :connection, :reconnect_scheduled],
      %{
        delay: System.convert_time_unit(delay, :millisecond, :native),
        attempt: data.reconnect.attempts + 1
      },
      connection_metadata(data)
    )
  end

  defp connection_metadata(data) do
    %{
      connection: self(),
      host: data.host,
      port: data.port
    }
  end

  defp telemetry_request_queued(request, data) do
    Telemetry.execute(
      [:s7, :request, :queued],
      %{system_time: System.system_time(), queue_depth: data.queued_count},
      request_metadata(request)
    )
  end

  defp telemetry_request_rejected(request, data, reason) do
    Telemetry.execute(
      [:s7, :request, :rejected],
      %{
        system_time: System.system_time(),
        queue_depth: data.queued_count,
        queue_duration: elapsed_since(request.enqueued_at)
      },
      Map.put(request_metadata(request), :reason, reason)
    )
  end

  defp telemetry_request_start(request, pdu, data) do
    started_at = Telemetry.monotonic_time()
    request_size = PDU.encoded_size(pdu)

    Telemetry.execute(
      [:s7, :request, :start],
      %{
        system_time: System.system_time(),
        queue_duration: elapsed_between(request.enqueued_at, started_at),
        request_size: request_size,
        in_flight: map_size(data.pending)
      },
      request_metadata(request)
    )

    %{request | started_at: started_at, request_size: request_size}
  end

  defp telemetry_request_stop(request, outcome, error, item_results, response_size) do
    if request.started_at do
      metadata =
        request
        |> request_metadata()
        |> Map.put(:outcome, outcome)
        |> Map.put(:item_error_count, item_error_count(item_results))
        |> put_telemetry_error(error)

      Telemetry.execute(
        [:s7, :request, :stop],
        %{
          duration: elapsed_since(request.started_at),
          request_size: request.request_size || 0,
          response_size: response_size
        },
        metadata
      )
    end

    %{request | started_at: nil, request_size: nil}
  end

  defp telemetry_request_stop(request, outcome, error),
    do: telemetry_request_stop(request, outcome, error, [], 0)

  defp stop_unfinished_request_span(%Request{started_at: nil} = request, _reply), do: request

  defp stop_unfinished_request_span(request, nil),
    do: telemetry_request_stop(request, :cancelled, nil)

  defp stop_unfinished_request_span(request, {:error, %Error{} = error}),
    do: telemetry_request_stop(request, :error, error)

  defp stop_unfinished_request_span(request, {:error, %Error{} = error, _results}),
    do: telemetry_request_stop(request, :error, error)

  defp stop_unfinished_request_span(request, _reply),
    do: telemetry_request_stop(request, :ok, nil)

  defp request_metadata(request) do
    %{
      connection: self(),
      request_id: request.id,
      operation: request.operation,
      reference: request.reference,
      item_count: request_item_count(request),
      raw: request.raw? == true
    }
  end

  defp request_item_count(%Request{current_batch: batch}) when is_list(batch),
    do: Enum.count(batch)

  defp request_item_count(%Request{batches: [batch | _batches]}), do: Enum.count(batch)
  defp request_item_count(_request), do: 0

  defp item_error_count(item_results),
    do: Enum.count(item_results, &match?({:error, %Error{}}, &1))

  defp telemetry_response_outcome(request, item_results) do
    cond do
      not caller_alive?(request) or request.cancelled -> :cancelled
      item_error_count(item_results) == 0 -> :ok
      request.kind in [:read_many, :write_many] -> :partial
      true -> :error
    end
  end

  defp put_telemetry_error(metadata, nil), do: metadata

  defp put_telemetry_error(metadata, %Error{} = error),
    do: Map.merge(metadata, %{error_layer: error.layer, error_reason: error.reason})

  defp elapsed_since(nil), do: 0
  defp elapsed_since(start_time), do: Telemetry.duration(start_time)
  defp elapsed_between(nil, _end_time), do: 0
  defp elapsed_between(start_time, end_time), do: max(end_time - start_time, 0)

  defp caller_alive?(%Request{from: {pid, _tag}}), do: Process.alive?(pid)
  defp caller_alive?(_request), do: false

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false)

  defp prepend_results(new_results, results),
    do: Enum.reduce(new_results, results, fn result, acc -> [result | acc] end)

  defp read_results(addresses, item_results) do
    Enum.zip_with(addresses, item_results, fn
      address, {:ok, value} -> %Result{address: address, status: :ok, value: value}
      address, {:error, error} -> %Result{address: address, status: :error, error: error}
    end)
  end

  defp write_results(items, item_results) do
    Enum.zip_with(items, item_results, fn
      {address, _value}, :ok ->
        %Result{address: address, status: :ok}

      {address, _value}, {:error, error} ->
        %Result{address: address, status: :error, error: error}
    end)
  end

  defp failed_results(addresses, status, error),
    do: Enum.map(addresses, &%Result{address: &1, status: status, error: error})

  defp failed_write_results(items, error, status) do
    Enum.map(items, fn {address, _value} ->
      %Result{address: address, status: status, error: error}
    end)
  end

  defp ensure_pdu_size(pdu, data, operation) do
    size = PDU.encoded_size(pdu)

    if size <= data.pdu_size do
      :ok
    else
      {:error,
       Error.new(:s7, operation, :pdu_too_large,
         details: %{size: size, negotiated_size: data.pdu_size}
       )}
    end
  end

  defp send_pdu(data, pdu, operation) do
    payload = pdu |> PDU.encode() |> IO.iodata_to_binary()

    case COTP.segment_data(payload, data.tpdu_size) do
      {:ok, tpdus} ->
        send_data_tpdus(data, tpdus, operation)

      {:error, reason} ->
        {:error, Error.new(:cotp, operation, reason, details: %{tpdu_size: data.tpdu_size})}
    end
  end

  defp send_data_tpdus(_data, [], _operation), do: :ok

  defp send_data_tpdus(data, [tpdu | tpdus], operation) do
    case send_cotp(data, tpdu, operation) do
      :ok -> send_data_tpdus(data, tpdus, operation)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp send_cotp(data, tpdu, operation) do
    payload = tpdu |> COTP.encode() |> IO.iodata_to_binary()
    frame = %TPKT{payload: payload} |> TPKT.encode()

    case :gen_tcp.send(data.socket, frame) do
      :ok -> :ok
      {:error, reason} -> {:error, tcp_error(operation, reason)}
    end
  end

  defp receive_pdu(data, operation) do
    deadline = deadline(data.timeout)

    case receive_cotp_data(data, deadline, operation, [], 0, 0) do
      {:ok, payload, data} -> decode_received_pdu(payload, data, operation)
      {:error, %Error{} = error, data} -> {:error, error, data}
    end
  end

  defp decode_received_pdu(payload, data, operation) do
    case decode_pdu(payload, operation) do
      {:ok, pdu, <<>>} ->
        {:ok, pdu, data}

      {:ok, _pdu, remaining} ->
        {:error,
         Error.new(:s7, operation, :malformed_response,
           details: %{trailing_bytes: byte_size(remaining)}
         ), data}

      {:more, needed} ->
        {:error, Error.new(:s7, operation, :malformed_response, details: %{bytes_needed: needed}),
         data}

      {:error, %Error{} = error} ->
        {:error, error, data}
    end
  end

  defp receive_cotp_data(data, deadline, operation, parts, count, size) do
    if count >= cotp_fragment_limit(data) do
      {:error, Error.new(:cotp, operation, :too_many_fragments), data}
    else
      receive_cotp_fragment(data, deadline, operation, parts, count, size)
    end
  end

  defp receive_cotp_fragment(data, deadline, operation, parts, count, size) do
    with {:ok, packet, data} <- receive_tpkt(data, deadline, operation),
         :ok <- validate_received_tpdu_size(packet.payload, data, operation),
         {:ok, tpdu} <- decode_cotp(packet.payload, operation),
         {:ok, payload, eot} <- cotp_data(tpdu, operation),
         :ok <- validate_reassembled_size(size + byte_size(payload), data, operation) do
      parts = [payload | parts]
      size = size + byte_size(payload)

      if eot do
        {:ok, parts |> Enum.reverse() |> IO.iodata_to_binary(), data}
      else
        receive_cotp_data(data, deadline, operation, parts, count + 1, size)
      end
    else
      {:error, %Error{} = error, data} -> {:error, error, data}
      {:error, %Error{} = error} -> {:error, error, data}
    end
  end

  defp cotp_fragment_limit(data) do
    payload_capacity = data.tpdu_size - 3
    required_fragments = div(data.pdu_size + payload_capacity - 1, payload_capacity)

    required_fragments
    |> max(@minimum_fragment_limit)
    |> min(@maximum_fragment_limit)
  end

  defp cotp_data(%Data{payload: payload, eot: eot, tpdu_number: 0}, _operation),
    do: {:ok, payload, eot}

  defp cotp_data(%Data{tpdu_number: received}, operation),
    do:
      {:error,
       Error.new(:cotp, operation, :unexpected_tpdu_number,
         details: %{expected: 0, received: received}
       )}

  defp cotp_data(%DisconnectRequest{} = request, operation),
    do:
      {:error,
       Error.new(:cotp, operation, :remote_disconnect,
         code: request.reason,
         details: %{
           destination_reference: request.destination_reference,
           source_reference: request.source_reference,
           additional_information: request.additional_information
         }
       )}

  defp cotp_data(%DisconnectConfirm{} = confirm, operation),
    do:
      {:error,
       Error.new(:cotp, operation, :unexpected_disconnect_confirm,
         details: %{
           destination_reference: confirm.destination_reference,
           source_reference: confirm.source_reference
         }
       )}

  defp cotp_data(%ErrorTPDU{} = tpdu, operation),
    do:
      {:error,
       Error.new(:cotp, operation, :protocol_error,
         code: tpdu.reject_cause,
         details: %{invalid_tpdu: tpdu.invalid_tpdu}
       )}

  defp cotp_data(_tpdu, operation),
    do: {:error, Error.new(:cotp, operation, :unexpected_tpdu)}

  defp validate_received_tpdu_size(payload, data, _operation)
       when byte_size(payload) <= data.tpdu_size,
       do: :ok

  defp validate_received_tpdu_size(payload, data, operation) do
    {:error,
     Error.new(:cotp, operation, :tpdu_too_large,
       details: %{size: byte_size(payload), negotiated_size: data.tpdu_size}
     )}
  end

  defp validate_reassembled_size(size, data, _operation) when size <= data.pdu_size, do: :ok

  defp validate_reassembled_size(size, data, operation) do
    {:error,
     Error.new(:s7, operation, :pdu_too_large,
       details: %{size: size, negotiated_size: data.pdu_size}
     )}
  end

  defp receive_tpkt(data, deadline, operation) do
    case TPKT.decode(data.receive_buffer, max_size: data.max_tpkt_size) do
      {:ok, packet, remaining} ->
        {:ok, packet, %{data | receive_buffer: remaining}}

      {:more, _needed} ->
        receive_more(data, deadline, operation)

      {:error, reason} ->
        {:error, Error.new(:tpkt, operation, :invalid_tpkt, details: %{codec_reason: reason}),
         data}
    end
  end

  defp receive_more(data, deadline, operation) do
    case remaining_timeout(deadline) do
      0 ->
        {:error, tcp_error(operation, :timeout), data}

      timeout ->
        case :gen_tcp.recv(data.socket, 0, timeout) do
          {:ok, bytes} ->
            append_receive_bytes(data, bytes, operation, deadline)

          {:error, reason} ->
            {:error, tcp_error(operation, reason), data}
        end
    end
  end

  defp append_receive_bytes(data, bytes, operation, deadline) do
    buffer = data.receive_buffer <> bytes

    if byte_size(buffer) <= data.receive_buffer_limit do
      receive_tpkt(%{data | receive_buffer: buffer}, deadline, operation)
    else
      {:error,
       Error.new(:tcp, operation, :receive_buffer_overflow,
         details: %{size: byte_size(buffer), limit: data.receive_buffer_limit}
       ), data}
    end
  end

  defp decode_cotp(payload, operation) do
    case COTP.decode(payload) do
      {:ok, tpdu} -> {:ok, tpdu}
      {:more, needed} -> codec_error(:cotp, operation, :invalid_cotp, %{bytes_needed: needed})
      {:error, reason} -> codec_error(:cotp, operation, :invalid_cotp, %{codec_reason: reason})
    end
  end

  defp decode_pdu(payload, operation) do
    case PDU.decode(payload) do
      {:ok, pdu, remaining} -> {:ok, pdu, remaining}
      {:more, needed} -> {:more, needed}
      {:error, reason} -> codec_error(:s7, operation, :invalid_s7_pdu, %{codec_reason: reason})
    end
  end

  defp codec_error(layer, operation, reason, details),
    do: {:error, Error.new(layer, operation, reason, details: details)}

  defp tcp_error(operation, reason) do
    public_reason =
      case reason do
        :econnrefused -> :connection_refused
        :timeout -> :timeout
        :closed -> :connection_closed
        _ -> :tcp_error
      end

    Error.new(:tcp, operation, public_reason, code: reason)
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp close_socket(%__MODULE__{socket: nil} = data), do: reset_connection(data)

  defp close_socket(%__MODULE__{socket: socket} = data) do
    :gen_tcp.close(socket)
    reset_connection(data)
  end

  defp reset_connection(data) do
    %{
      data
      | socket: nil,
        receive_buffer: <<>>,
        stream: Stream.new(),
        session: %{local_reference: nil, remote_reference: nil, authenticated: false}
    }
  end

  defp with_operation(%Error{} = error, operation), do: %{error | operation: operation}

  defp connection_action(%Error{layer: :tcp}), do: :disconnect
  defp connection_action(_error), do: :keep

  defp response_action(%Error{reason: reason})
       when reason in [
              :invalid_cotp,
              :invalid_s7_pdu,
              :malformed_response,
              :unexpected_pdu_reference,
              :unexpected_rosctr,
              :unexpected_userdata_service,
              :unexpected_userdata_type,
              :unexpected_tpdu,
              :unexpected_tpdu_number,
              :too_many_userdata_fragments,
              :userdata_too_large
            ],
       do: :disconnect

  defp response_action(error), do: connection_action(error)

  defp operation_name({:userdata, _message, operation}) when is_atom(operation), do: operation

  defp operation_name({:read_szl, _id, _index, _limits, operation}) when is_atom(operation),
    do: operation

  defp operation_name({:blocks, :counts}), do: :block_counts
  defp operation_name({:blocks, :list, _type, _limits}), do: :list_blocks
  defp operation_name({:blocks, :info, _block}), do: :block_info
  defp operation_name({:clock, :read}), do: :read_clock
  defp operation_name({:clock, :set, _datetime}), do: :set_clock
  defp operation_name({:security, :login, _password}), do: :authenticate
  defp operation_name({:security, :logout}), do: :logout

  defp operation_name({:begin_transaction, operation, _opts}) when is_atom(operation),
    do: operation

  defp operation_name({operation, _token, _value})
       when operation in [
              :transaction_request,
              :transaction_receive,
              :transaction_reply,
              :abort_transaction
            ],
       do: operation

  defp operation_name({operation, _value})
       when operation in [
              :end_transaction,
              :unsubscribe_userdata,
              :validate_userdata_subscription
            ],
       do: operation

  defp operation_name({:subscribe_userdata, _filter, _opts}), do: :subscribe_userdata

  defp operation_name({:rebind_userdata_subscription, _subscription, _filter}),
    do: :next_userdata

  defp operation_name({:next_userdata, _subscription, _timeout}), do: :next_userdata

  defp operation_name({operation, _address, _value}), do: operation
  defp operation_name({operation, _items}) when operation in [:write_many], do: operation
  defp operation_name(operation) when is_atom(operation), do: operation
  defp operation_name(_operation), do: :request
end
