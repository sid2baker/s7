defmodule S7.Connection do
  @moduledoc """
  Stateful S7 connection process.

  This `:gen_statem` owns the TCP socket and serializes v0.1 requests. Callers
  interact through `S7.Client`; protocol modules remain independent of this
  lifecycle layer.
  """

  @behaviour :gen_statem

  alias S7.{Address, Error, TSAP}
  alias S7.Protocol.{PDU, ReadVar, SetupCommunication, WriteVar}
  alias S7.Transport.{COTP, TPKT}
  alias S7.Transport.COTP.{ConnectionConfirm, ConnectionRequest, Data}

  @default_port 102
  @default_timeout 5_000
  @default_tpdu_size 1024
  @default_pdu_size 480
  @maximum_fragments 64
  @maximum_tpkt_size 0xFFFF

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
    :pdu_size,
    :max_jobs,
    :reference,
    receive_buffer: <<>>,
    max_tpkt_size: @maximum_tpkt_size
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
  @spec write(pid(), Address.t(), binary()) :: :ok | {:error, Error.t()}
  def write(connection, address, value) do
    :gen_statem.call(connection, {:write, address, value}, :infinity)
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
        {:next_state, :ready, data, [{:reply, from, :ok}]}

      {:error, error, data} ->
        {:next_state, :disconnected, close_socket(data), [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, :connect, state, _data) when state != :disconnected do
    error = Error.new(:client, :connect, :already_connected)
    {:keep_state_and_data, [{:reply, from, {:error, error}}]}
  end

  def handle_event({:call, from}, {:read, address, raw?}, :ready, data) do
    reference = data.reference
    data = %{data | reference: next_reference(reference)}

    case perform_read(data, address, raw?, reference) do
      {:ok, value, data} ->
        {:keep_state, data, [{:reply, from, {:ok, value}}]}

      {:error, error, data, :keep} ->
        {:keep_state, data, [{:reply, from, {:error, error}}]}

      {:error, error, data, :disconnect} ->
        {:next_state, :disconnected, close_socket(data), [{:reply, from, {:error, error}}]}
    end
  end

  def handle_event({:call, from}, {:write, address, value}, :ready, data) do
    reference = data.reference
    data = %{data | reference: next_reference(reference)}

    case perform_write(data, address, value, reference) do
      {:ok, data} ->
        {:keep_state, data, [{:reply, from, :ok}]}

      {:error, error, data, :keep} ->
        {:keep_state, data, [{:reply, from, {:error, error}}]}

      {:error, error, data, :disconnect} ->
        {:next_state, :disconnected, close_socket(data), [{:reply, from, {:error, error}}]}
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
      tpdu_size: data.tpdu_size,
      next_reference: data.reference
    }

    {:keep_state_and_data, [{:reply, from, info}]}
  end

  def handle_event({:call, from}, :close, _state, data) do
    {:stop_and_reply, :normal, [{:reply, from, :ok}], close_socket(data)}
  end

  def handle_event(:info, {:tcp_closed, socket}, _state, %{socket: socket} = data) do
    {:next_state, :disconnected, %{data | socket: nil, receive_buffer: <<>>}}
  end

  def handle_event(:info, {:tcp_error, socket, _reason}, _state, %{socket: socket} = data) do
    {:next_state, :disconnected, close_socket(data)}
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
         {:ok, tpdu_size} <- tpdu_size(opts),
         {:ok, pdu_size} <- positive_option(opts, :pdu_size, @default_pdu_size, 0xFFFF),
         :ok <- validate_minimum_pdu(pdu_size),
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
         requested_setup: %SetupCommunication{pdu_length: pdu_size},
         pdu_size: pdu_size,
         max_jobs: 1,
         reference: reference,
         max_tpkt_size: max_tpkt_size
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

      {:ok,
       %{
         data
         | pdu_size: pdu_size,
           max_jobs: 1,
           requested_setup: setup
       }}
    else
      {:error, %Error{} = error, data} -> {:error, error, data}
      {:error, %Error{} = error} -> {:error, error, data}
    end
  end

  defp perform_read(data, address, raw?, reference) do
    with {:ok, request} <- ReadVar.request(address, reference),
         :ok <- ensure_pdu_size(request, data, :read),
         :ok <- send_pdu(data, request, :read),
         {:ok, response, data} <- receive_pdu(data, :read) do
      decoder = if raw?, do: &ReadVar.decode_raw_response/3, else: &ReadVar.decode_response/3

      case decoder.(response, address, reference) do
        {:ok, value} -> {:ok, value, data}
        {:error, error} -> {:error, error, data, :keep}
      end
    else
      {:error, %Error{} = error, data} -> {:error, error, data, :disconnect}
      {:error, %Error{} = error} -> {:error, error, data, connection_action(error)}
    end
  end

  defp perform_write(data, address, value, reference) do
    with {:ok, request} <- WriteVar.request(address, value, reference),
         :ok <- ensure_pdu_size(request, data, :write),
         :ok <- send_pdu(data, request, :write),
         {:ok, response, data} <- receive_pdu(data, :write),
         :ok <- WriteVar.decode_response(response, reference) do
      {:ok, data}
    else
      {:error, %Error{} = error, data} -> {:error, error, data, :disconnect}
      {:error, %Error{} = error} -> {:error, error, data, connection_action(error)}
    end
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

  defp cotp_data(%Data{payload: payload, eot: eot}, _operation), do: {:ok, payload, eot}

  defp cotp_data(_tpdu, operation),
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
            data = %{data | receive_buffer: data.receive_buffer <> bytes}
            receive_tpkt(data, deadline, operation)

          {:error, reason} ->
            {:error, tcp_error(operation, reason), data}
        end
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

  defp close_socket(%__MODULE__{socket: nil} = data), do: data

  defp close_socket(%__MODULE__{socket: socket} = data) do
    :gen_tcp.close(socket)
    %{data | socket: nil, receive_buffer: <<>>}
  end

  defp connection_action(%Error{layer: :tcp}), do: :disconnect
  defp connection_action(_error), do: :keep

  defp operation_name({operation, _address, _value}), do: operation
  defp operation_name(operation) when is_atom(operation), do: operation
  defp operation_name(_operation), do: :request
end
