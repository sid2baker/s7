defmodule S7.Connection do
  @moduledoc """
  Stateful S7 connection process.

  This `:gen_statem` owns the TCP socket, queues callers, and correlates active
  requests by S7 PDU reference. Callers interact through `S7.Client`; protocol
  modules remain independent of this lifecycle layer.
  """

  @behaviour :gen_statem

  alias S7.{Address, Error, Result, Telemetry, TSAP}
  alias S7.Connection.{Drain, Reconnect, Request, Stream}
  alias S7.Protocol.{PDU, PDUPlanner, ReadVar, SetupCommunication, UserData, WriteVar}
  alias S7.Transport.{COTP, TPKT}

  alias S7.Transport.COTP.{
    ConnectionConfirm,
    ConnectionRequest,
    Data,
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
  @maximum_fragments 64
  @maximum_tpkt_size 0xFFFF
  @maximum_receive_buffer_size 1_048_576
  @connection_options [
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
    :remote_reference,
    :requested_setup,
    :negotiated_setup,
    :pdu_size,
    :max_jobs,
    :max_items_per_pdu,
    :max_queue_size,
    :reference,
    :receive_buffer_limit,
    :stream,
    :reconnect,
    :drain,
    receive_buffer: <<>>,
    max_tpkt_size: @maximum_tpkt_size,
    queue: {[], []},
    queued_count: 0,
    pending: %{},
    request_index: %{}
  ]

  @type state_name ::
          :disconnected
          | :tcp_connected
          | :cotp_connected
          | :s7_negotiating
          | :ready
          | :reconnecting
          | :draining

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
  @spec read_multi(pid(), [Address.t()], boolean()) ::
          {:ok, [Result.t()]} | {:error, Error.t(), [Result.t()]}
  def read_multi(connection, addresses, raw?) do
    :gen_statem.call(connection, {:read_multi, addresses, raw?}, :infinity)
  end

  @doc false
  @spec write(pid(), Address.t(), binary()) :: :ok | {:error, Error.t()}
  def write(connection, address, value) do
    :gen_statem.call(connection, {:write, address, value}, :infinity)
  end

  @doc false
  @spec write_multi(pid(), [{Address.t(), binary()}]) ::
          {:ok, [Result.t()]} | {:error, Error.t(), [Result.t()]}
  def write_multi(connection, items) do
    :gen_statem.call(connection, {:write_multi, items}, :infinity)
  end

  @doc false
  @spec userdata(pid(), UserData.t(), atom()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def userdata(connection, message, operation \\ :userdata) do
    :gen_statem.call(connection, {:userdata, message, operation}, :infinity)
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

  def handle_event({:call, from}, {:read_multi, _addresses, _raw?} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:write_multi, _items} = operation, :ready, data),
    do: submit_request(from, operation, data)

  def handle_event(
        {:call, from},
        {:userdata, _message, _request_operation} = operation,
        :ready,
        data
      ),
      do: submit_request(from, operation, data)

  def handle_event({:call, from}, {:close, opts}, :ready, data) do
    case close_options(opts, data.timeout) do
      {:ok, :immediate, _timeout} -> close_immediately(from, data)
      {:ok, :drain, timeout} -> begin_drain(from, data, timeout)
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, {:close, opts}, :draining, data) do
    case close_options(opts, data.timeout) do
      {:ok, :immediate, _timeout} -> close_immediately(from, data)
      {:ok, :drain, _timeout} -> reply_already_draining(from)
      {:error, error} -> {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, {:close, opts}, _state, data) do
    case close_options(opts, data.timeout) do
      {:ok, _mode, _timeout} -> close_immediately(from, data)
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
      reconnect_delay: data.reconnect.delay
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

      {:disconnect, error, data} ->
        disconnect_with_error(state, data, error)
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
    data = cancel_request(data, monitor)

    if state == :draining and requests_idle?(data) do
      complete_drain(data)
    else
      {:keep_state, data}
    end
  end

  def handle_event(
        :info,
        {:drain_timeout, token},
        :draining,
        %{drain: %Drain{token: token}} = data
      ) do
    error = Error.new(:client, :close, :drain_timeout)
    fail_drain(data, error)
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
    data |> cancel_reconnect() |> cancel_drain() |> close_socket()
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
         reference: reference,
         receive_buffer_limit: receive_buffer_limit,
         max_tpkt_size: max_tpkt_size,
         stream: Stream.new(),
         reconnect: struct!(Reconnect, Map.put(reconnect, :delay, reconnect.min_delay)),
         drain: %Drain{}
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
      close_immediately(from, data)
    else
      token = make_ref()
      timer = Process.send_after(self(), {:drain_timeout, token}, timeout)

      {:next_state, :draining, %{data | drain: %Drain{from: from, timer: timer, token: token}}}
    end
  end

  defp close_immediately(from, data) do
    reply_closing_caller(data, :ok)
    error = Error.new(:client, :request, :connection_closed)
    telemetry_connection_disconnected(data, error)

    data =
      data
      |> cancel_reconnect()
      |> cancel_drain()
      |> fail_all_requests(error)
      |> close_socket()

    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  defp reply_already_draining(from) do
    error = Error.new(:client, :close, :already_closing)
    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  defp complete_drain(data) do
    reply_closing_caller(data, :ok)
    telemetry_connection_disconnected(data, Error.new(:client, :close, :connection_closed))
    data = data |> cancel_drain() |> close_socket()
    {:stop, :normal, data}
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

  defp reply_closing_caller(%{drain: %Drain{from: nil}}, _reply), do: :ok
  defp reply_closing_caller(data, reply), do: :gen_statem.reply(data.drain.from, reply)

  defp cancel_drain(data) do
    cancel_timer(data.drain.timer)
    %{data | drain: %Drain{}}
  end

  defp requests_idle?(data), do: map_size(data.pending) == 0 and data.queued_count == 0

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

    %{
      data
      | pending: %{},
        queue: :queue.new(),
        queued_count: 0,
        request_index: %{}
    }
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
      {:ok, %{data | tpdu_size: tpdu_size, remote_reference: confirm.source_reference}}
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

  defp build_request(from, {:read_multi, addresses, raw?}, data) do
    with {:ok, batches} <- plan_read(addresses, data) do
      {:ok, new_request(from, :read_multi, :read_multi, batches, raw?)}
    end
  end

  defp build_request(from, {:write, address, value}, data) do
    with {:ok, batches} <- plan_write([{address, value}], data) do
      {:ok, new_request(from, :write, :write, batches)}
    end
  end

  defp build_request(from, {:write_multi, items}, data) do
    with {:ok, batches} <- plan_write(items, data) do
      {:ok, new_request(from, :write_multi, :write_multi, batches)}
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
    if map_size(data.pending) >= data.max_jobs and data.queued_count >= data.max_queue_size do
      telemetry_request_rejected(request, data, :queue_full)

      {:error,
       Error.new(:client, request.operation, :queue_full, details: %{limit: data.max_queue_size})}
    else
      :ok
    end
  end

  defp monitor_request(%Request{from: {pid, _tag}} = request) do
    %{request | monitor: Process.monitor(pid)}
  end

  defp enqueue_request(data, request) do
    queue = :queue.in(request, data.queue)
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

  defp schedule_requests(data)
       when map_size(data.pending) >= data.max_jobs or data.queued_count == 0,
       do: {:ok, data}

  defp schedule_requests(data) do
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
         :ok <- ensure_pdu_size(pdu, data, request.operation) do
      request = telemetry_request_start(request, pdu, data)

      case send_pdu(data, pdu, request.operation) do
        :ok ->
          token = make_ref()
          timer = Process.send_after(self(), {:request_timeout, reference, token}, data.timeout)
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
       when kind in [:read, :read_multi],
       do: ReadVar.request_many(batch, reference)

  defp encode_batch(%Request{kind: kind}, batch, reference)
       when kind in [:write, :write_multi],
       do: WriteVar.request_many(batch, reference)

  defp encode_batch(%Request{kind: :userdata}, [%UserData{} = message], reference),
    do: UserData.to_pdu(message, reference)

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

  defp handle_received_pdus(
         [%PDU{header: %{rosctr: :userdata}} = pdu | pdus],
         data
       ) do
    case UserData.from_pdu(pdu) do
      {:ok, %UserData{parameter: %{type: :indication}} = message} ->
        telemetry_unhandled_userdata(message, pdu)
        handle_received_pdus(pdus, data)

      {:ok, _message} ->
        handle_correlatable_pdu(pdu, pdus, data)

      {:error, %Error{} = error} ->
        {:disconnect, error, data}
    end
  end

  defp handle_received_pdus([pdu | pdus], data),
    do: handle_correlatable_pdu(pdu, pdus, data)

  defp handle_correlatable_pdu(pdu, pdus, data) do
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
       when kind in [:read, :read_multi] do
    decoder = if raw?, do: &ReadVar.decode_raw_responses/3, else: &ReadVar.decode_responses/3
    decoder.(pdu, request.current_batch, request.reference)
  end

  defp decode_batch_response(%Request{kind: kind} = request, pdu)
       when kind in [:write, :write_multi] do
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

  defp handle_active_batch_results(data, %Request{kind: :read_multi} = request, item_results) do
    results = prepend_results(read_results(request.current_batch, item_results), request.results)
    continue_or_finish(data, %{request | results: results})
  end

  defp handle_active_batch_results(data, %Request{kind: :write_multi} = request, item_results) do
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
       when kind in [:read, :write, :userdata],
       do: {:error, with_operation(error, operation)}

  defp request_failure_reply(%Request{kind: :read_multi} = request, error, send_state) do
    error = with_operation(error, request.operation)
    results = failed_multi_results(request, error, send_state, :error)
    {:error, error, results}
  end

  defp request_failure_reply(%Request{kind: :write_multi} = request, error, send_state) do
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

  defp failed_batch(kind, items, status, error) when kind in [:read, :read_multi],
    do: failed_results(items, status, error)

  defp failed_batch(kind, items, status, error) when kind in [:write, :write_multi],
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
      request.kind in [:read_multi, :write_multi] -> :partial
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

  defp receive_cotp_data(data, _deadline, operation, _parts, count, _size)
       when count >= @maximum_fragments do
    {:error, Error.new(:cotp, operation, :too_many_fragments), data}
  end

  defp receive_cotp_data(data, deadline, operation, parts, count, size) do
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
         details: %{additional_information: request.additional_information}
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
        remote_reference: nil,
        receive_buffer: <<>>,
        stream: Stream.new()
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
              :unexpected_tpdu_number
            ],
       do: :disconnect

  defp response_action(error), do: connection_action(error)

  defp operation_name({:userdata, _message, operation}) when is_atom(operation), do: operation
  defp operation_name({operation, _address, _value}), do: operation
  defp operation_name({operation, _items}) when operation in [:write_multi], do: operation
  defp operation_name(operation) when is_atom(operation), do: operation
  defp operation_name(_operation), do: :request
end
