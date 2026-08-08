defmodule S7.Connection do
  @moduledoc """
  Stateful S7 connection process.

  This `:gen_statem` owns the TCP socket, queues callers, and correlates active
  requests by S7 PDU reference. Callers interact through `S7.Client`; protocol
  modules remain independent of this lifecycle layer.
  """

  @behaviour :gen_statem

  alias S7.{Address, Error, Result, TSAP}
  alias S7.Connection.{Request, Stream}
  alias S7.Protocol.{PDU, PDUPlanner, ReadVar, SetupCommunication, WriteVar}
  alias S7.Transport.{COTP, TPKT}
  alias S7.Transport.COTP.{ConnectionConfirm, ConnectionRequest, Data}

  @default_port 102
  @default_timeout 5_000
  @default_tpdu_size 1024
  @default_pdu_size 480
  @default_maximum_items 20
  @default_queue_limit 64
  @maximum_fragments 64
  @maximum_tpkt_size 0xFFFF
  @maximum_receive_buffer_size 1_048_576

  defstruct [
    :host,
    :port,
    :socket,
    :timeout,
    :src_tsap,
    :dst_tsap,
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
    receive_buffer: <<>>,
    max_tpkt_size: @maximum_tpkt_size,
    queue: {[], []},
    queued_count: 0,
    pending: %{},
    request_index: %{}
  ]

  @type state_name ::
          :disconnected | :tcp_connected | :cotp_connected | :s7_negotiating | :ready

  @type t :: %__MODULE__{}

  @doc false
  @spec start(term(), keyword()) :: :gen_statem.start_ret()
  def start(host, opts \\ []) do
    :gen_statem.start(__MODULE__, {host, opts}, [])
  end

  @doc false
  @spec start_link(term(), keyword()) :: :gen_statem.start_ret()
  def start_link(host, opts \\ []) do
    :gen_statem.start_link(__MODULE__, {host, opts}, [])
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
  @spec close(pid()) :: :ok
  def close(connection), do: :gen_statem.call(connection, :close, :infinity)

  @doc false
  @spec info(pid()) :: map() | {:error, Error.t()}
  def info(connection), do: :gen_statem.call(connection, :info, :infinity)

  @doc false
  @spec next_reference(0..0xFFFF) :: 1..0xFFFF
  def next_reference(0xFFFF), do: 1
  def next_reference(reference) when reference in 0..0xFFFE, do: reference + 1

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
    case open_tcp(data) do
      {:ok, data} ->
        {:next_state, :tcp_connected, data, [{:next_event, :internal, {:connect_cotp, from}}]}

      {:error, error} ->
        {:keep_state_and_data, [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event(:internal, {:connect_cotp, from}, :tcp_connected, data) do
    case negotiate_cotp(data) do
      {:ok, data} ->
        {:next_state, :cotp_connected, data, [{:next_event, :internal, {:negotiate_s7, from}}]}

      {:error, error, data} ->
        {:next_state, :disconnected, close_socket(data), [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event(:internal, {:negotiate_s7, from}, :cotp_connected, data) do
    reference = data.reference
    data = %{data | reference: next_reference(data.reference)}

    case negotiate_s7(data, reference) do
      {:ok, data} ->
        case activate_socket(data) do
          {:ok, data} ->
            {:next_state, :ready, data, [{:reply, from, :ok}]}

          {:error, error} ->
            {:next_state, :disconnected, close_socket(data),
             [
               {:reply, from, {:error, error}}
             ]}
        end

      {:error, error, data} ->
        {:next_state, :disconnected, close_socket(data), [{:reply, from, {:error, error}}]}
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
      socket_mode: if(data.socket, do: :active_once, else: :closed)
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  def handle_event({:call, from}, :close, _state, data) do
    error = Error.new(:client, :request, :connection_closed)
    data = data |> fail_all_requests(error) |> close_socket()
    {:stop_and_reply, :normal, [{:reply, from, :ok}], data}
  end

  def handle_event(:info, {:tcp, socket, bytes}, :ready, %{socket: socket} = data) do
    case receive_active_bytes(data, bytes) do
      {:ok, data} ->
        case schedule_requests(data) do
          {:ok, data} -> rearm_or_disconnect(data)
          {:disconnect, error, data} -> disconnect_with_error(data, error)
        end

      {:disconnect, error, data} ->
        disconnect_with_error(data, error)
    end
  end

  def handle_event(:info, {:request_timeout, reference, token}, :ready, data) do
    case data.pending do
      %{^reference => %Request{timer_token: ^token} = request} ->
        error = Error.new(:tcp, request.operation, :timeout)
        disconnect_with_error(data, error)

      _other ->
        :keep_state_and_data
    end
  end

  def handle_event(:info, {:DOWN, monitor, :process, _pid, _reason}, :ready, data) do
    {:keep_state, cancel_request(data, monitor)}
  end

  def handle_event(:info, {:tcp_closed, socket}, _state, %{socket: socket} = data) do
    error = Error.new(:tcp, :request, :connection_closed)
    data = data |> fail_all_requests(error) |> reset_connection()
    {:next_state, :disconnected, data}
  end

  def handle_event(:info, {:tcp_error, socket, reason}, _state, %{socket: socket} = data) do
    error = tcp_error(:request, reason)
    data = data |> fail_all_requests(error) |> close_socket()
    {:next_state, :disconnected, data}
  end

  def handle_event(_event_type, _event_content, _state, _data), do: :keep_state_and_data

  @impl :gen_statem
  def terminate(_reason, _state, data) do
    close_socket(data)
    :ok
  end

  defp build_state(host, opts) when is_list(opts) do
    with :ok <- validate_host(host),
         {:ok, port} <- positive_option(opts, :port, @default_port, 0xFFFF),
         {:ok, timeout} <- positive_option(opts, :timeout, @default_timeout, :infinity),
         {:ok, max_tpkt_size} <-
           positive_option(opts, :max_tpkt_size, @maximum_tpkt_size, @maximum_tpkt_size),
         :ok <- validate_minimum_tpkt(max_tpkt_size),
         {:ok, receive_buffer_limit} <- receive_buffer_limit(opts, max_tpkt_size),
         {:ok, tpdu_size} <- tpdu_size(opts),
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
         stream: Stream.new()
       }}
    end
  end

  defp build_state(_host, opts),
    do: {:error, Error.new(:client, :connect, :invalid_options, details: %{options: opts})}

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

  defp activate_socket(data) do
    case :inet.setopts(data.socket, active: :once) do
      :ok ->
        stream = Stream.new(data.receive_buffer)
        {:ok, %{data | receive_buffer: <<>>, stream: stream}}

      {:error, reason} ->
        {:error, tcp_error(:connect, reason)}
    end
  end

  defp rearm_or_disconnect(data) do
    case :inet.setopts(data.socket, active: :once) do
      :ok -> {:keep_state, data}
      {:error, reason} -> disconnect_with_error(data, tcp_error(:request, reason))
    end
  end

  defp disconnect_with_error(data, error) do
    data = data |> fail_all_requests(error) |> close_socket()
    {:next_state, :disconnected, data}
  end

  defp fail_all_requests(data, error) do
    Enum.each(data.pending, fn {_reference, request} ->
      finish_request(request, request_failure_reply(request, error, :sent))
    end)

    data.queue
    |> :queue.to_list()
    |> Enum.each(fn request ->
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
        remaining = Enum.reject(requests, &(&1.id == request_id))

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
      tpdu_size: data.tpdu_size
    }

    with :ok <- send_cotp(data, request, :connect),
         {:ok, packet, data} <- receive_tpkt(data, deadline(data.timeout), :connect),
         {:ok, confirm} <- decode_cotp(packet.payload, :connect),
         :ok <- validate_confirm(confirm, request) do
      tpdu_size = min(data.tpdu_size, confirm.tpdu_size || data.tpdu_size)
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
        {:disconnect, error, data} -> disconnect_with_error(data, error)
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
      raw?: raw?
    }
  end

  defp admit_request(data, request) do
    if map_size(data.pending) >= data.max_jobs and data.queued_count >= data.max_queue_size do
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

    %{
      data
      | queue: queue,
        queued_count: data.queued_count + 1,
        request_index: request_index
    }
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
      finish_request(request, nil)
      schedule_requests(data)
    end
  end

  defp schedule_dispatched_request(result) do
    case result do
      {:ok, data} ->
        schedule_requests(data)

      {:error, error, request, data} ->
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
         :ok <- send_pdu(data, pdu, request.operation) do
      token = make_ref()
      timer = Process.send_after(self(), {:request_timeout, reference, token}, data.timeout)

      request = %{request | timer: timer, timer_token: token}

      pending = Map.put(data.pending, reference, request)
      request_index = Map.put(data.request_index, request.monitor, {:pending, reference})
      {:ok, %{data | pending: pending, request_index: request_index}}
    else
      {:error, %Error{layer: :tcp} = error} -> {:disconnect, error, request, data}
      {:error, %Error{} = error} -> {:error, error, request, data}
    end
  end

  defp encode_batch(%Request{kind: kind}, batch, reference)
       when kind in [:read, :read_multi],
       do: ReadVar.request_many(batch, reference)

  defp encode_batch(%Request{kind: kind}, batch, reference)
       when kind in [:write, :write_multi],
       do: WriteVar.request_many(batch, reference)

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
      pdu_size: data.pdu_size
    ]

    case Stream.push(data.stream, bytes, opts) do
      {:ok, pdus, stream} -> handle_received_pdus(pdus, %{data | stream: stream})
      {:error, %Error{} = error} -> {:disconnect, error, data}
    end
  end

  defp handle_received_pdus([], data), do: {:ok, data}

  defp handle_received_pdus([pdu | pdus], data) do
    reference = pdu.header.pdu_reference

    case take_pending(data, reference) do
      {:ok, request, data} ->
        handle_correlated_pdu(decode_batch_response(request, pdu), request, pdus, data)

      :error ->
        error =
          Error.new(:s7, :request, :unexpected_pdu_reference,
            details: %{received: reference, pending: Map.keys(data.pending)}
          )

        {:disconnect, error, data}
    end
  end

  defp handle_correlated_pdu({:ok, item_results}, request, pdus, data) do
    data = handle_batch_results(data, request, item_results)
    handle_received_pdus(pdus, data)
  end

  defp handle_correlated_pdu({:error, %Error{} = error}, request, pdus, data) do
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
    request = %{request | reference: nil, current_batch: nil}
    enqueue_request(data, request)
  end

  defp request_failure_reply(%Request{kind: kind}, error, _send_state)
       when kind in [:read, :write],
       do: {:error, with_operation(error, kind)}

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
    cancel_timer(request.timer)

    if request.monitor do
      Process.demonitor(request.monitor, [:flush])
    end

    if request.from && not request.cancelled && reply do
      :gen_statem.reply(request.from, reply)
    end

    :ok
  end

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
    send_cotp(data, %Data{payload: payload}, operation)
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
         {:ok, tpdu} <- decode_cotp(packet.payload, operation),
         {:ok, payload, eot} <- cotp_data(tpdu, operation, rem(count, 0x80)),
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

  defp cotp_data(%Data{payload: payload, eot: eot, tpdu_number: expected}, _operation, expected),
    do: {:ok, payload, eot}

  defp cotp_data(%Data{tpdu_number: received}, operation, expected),
    do:
      {:error,
       Error.new(:cotp, operation, :unexpected_tpdu_number,
         details: %{expected: expected, received: received}
       )}

  defp cotp_data(_tpdu, operation, _expected),
    do: {:error, Error.new(:cotp, operation, :unexpected_tpdu)}

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
              :unexpected_tpdu,
              :unexpected_tpdu_number
            ],
       do: :disconnect

  defp response_action(error), do: connection_action(error)

  defp operation_name({operation, _address, _value}), do: operation
  defp operation_name({operation, _items}) when operation in [:write_multi], do: operation
  defp operation_name(operation) when is_atom(operation), do: operation
  defp operation_name(_operation), do: :request
end
