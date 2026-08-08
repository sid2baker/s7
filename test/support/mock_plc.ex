defmodule S7.Test.MockPLC do
  @moduledoc false

  alias S7.Connection
  alias S7.Protocol.{DataItem, Item, PDU, SetupCommunication}
  alias S7.Transport.{COTP, TPKT}
  alias S7.Transport.COTP.{ConnectionConfirm, ConnectionRequest, Data}

  defstruct [:pid, :port]

  def start_link(opts \\ []) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    pid =
      spawn_link(fn ->
        run(listener, owner, opts)
      end)

    {:ok, %__MODULE__{pid: pid, port: port}}
  end

  def stop(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp run(listener, owner, opts) do
    {:ok, socket} = :gen_tcp.accept(listener, 2_000)
    :ok = :gen_tcp.close(listener)

    state = %{
      socket: socket,
      owner: owner,
      buffer: <<>>,
      options: opts,
      read_fault: Keyword.get(opts, :read_fault),
      memory: initial_memory()
    }

    state
    |> accept_cotp()
    |> accept_setup()
    |> serve()
  end

  defp accept_cotp(state) do
    {:ok, packet, state} = receive_tpkt(state)
    {:ok, %ConnectionRequest{} = request} = COTP.decode(packet.payload)

    confirm = %ConnectionConfirm{
      src_tsap: request.dst_tsap,
      dst_tsap: request.src_tsap,
      tpdu_size: request.tpdu_size,
      destination_reference: request.source_reference,
      source_reference: 1
    }

    :ok = send_tpdu(state, confirm)
    state
  end

  defp accept_setup(state) do
    {:ok, request, state} = receive_pdu(state)
    {:ok, requested_setup} = SetupCommunication.decode(request.parameters)
    negotiated_pdu = Keyword.get(state.options, :negotiated_pdu, 240)

    response_setup = %SetupCommunication{
      max_amq_calling: min(requested_setup.max_amq_calling, 1),
      max_amq_called: min(requested_setup.max_amq_called, 1),
      pdu_length: min(requested_setup.pdu_length, negotiated_pdu)
    }

    response =
      PDU.new(:ack_data, request.header.pdu_reference, SetupCommunication.encode(response_setup))

    :ok = send_pdu(state, response)
    state
  end

  defp serve(state) do
    case receive_pdu(state) do
      {:ok, %PDU{parameters: <<0x04, 1, item_binary::binary>>} = request, state} ->
        state
        |> handle_read(request, item_binary)
        |> serve()

      {:ok, %PDU{parameters: <<0x05, 1, item_binary::binary>>} = request, state} ->
        state
        |> handle_write(request, item_binary)
        |> serve()

      {:error, :closed} ->
        send(state.owner, :mock_plc_closed)
        :ok
    end
  end

  defp handle_read(%{read_fault: :wrong_reference} = state, request, _item_binary) do
    response = successful_read_response(request, :word, <<0x04, 0xD2>>)

    response =
      put_in(
        response.header.pdu_reference,
        Connection.next_reference(request.header.pdu_reference)
      )

    :ok = send_pdu(state, response)
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :truncated_payload} = state, request, _item_binary) do
    response =
      PDU.new(
        :ack_data,
        request.header.pdu_reference,
        <<0x04, 1>>,
        <<0xFF, 0x04, 0, 16, 1>>
      )

    :ok = send_pdu(state, response)
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :silence} = state, _request, _item_binary) do
    %{state | read_fault: nil}
  end

  defp handle_read(state, request, item_binary) do
    {:ok, item, <<>>} = Item.decode(item_binary)
    key = memory_key(item)

    response =
      case Map.fetch(state.memory, key) do
        {:ok, data} -> successful_read_response(request, item.transport_size, data)
        :error -> failed_read_response(request, 0x0A)
      end

    :ok = send_pdu(state, response)
    state
  end

  defp handle_write(state, request, item_binary) do
    {:ok, item, <<>>} = Item.decode(item_binary)
    {:ok, data_item, <<>>} = DataItem.decode(request.data)
    memory = Map.put(state.memory, memory_key(item), data_item.data)

    response = PDU.new(:ack_data, request.header.pdu_reference, <<0x05, 1>>, <<0xFF>>)
    :ok = send_pdu(state, response)
    %{state | memory: memory}
  end

  defp successful_read_response(request, data_type, data) do
    item = %{DataItem.for_write(data_type, data) | return_code: 0xFF}
    encoded_item = item |> DataItem.encode() |> IO.iodata_to_binary()
    PDU.new(:ack_data, request.header.pdu_reference, <<0x04, 1>>, encoded_item)
  end

  defp failed_read_response(request, code) do
    PDU.new(:ack_data, request.header.pdu_reference, <<0x04, 1>>, <<code, 0, 0, 0>>)
  end

  defp memory_key(item) do
    {item.area, item.db_number, item.transport_size, item.bit_address}
  end

  defp initial_memory do
    %{
      {:db, 1, :bit, 0} => <<1>>,
      {:db, 1, :word, 0} => <<0x04, 0xD2>>,
      {:db, 1, :byte, 8} => <<0xA5>>,
      {:db, 1, :word, 16} => <<0x12, 0x34>>,
      {:db, 1, :dword, 32} => <<1, 2, 3, 4>>,
      {:inputs, 0, :bit, 0} => <<1>>,
      {:inputs, 0, :byte, 0} => <<0x11>>,
      {:inputs, 0, :word, 0} => <<0x11, 0x22>>,
      {:outputs, 0, :bit, 0} => <<0>>,
      {:outputs, 0, :byte, 0} => <<0x22>>,
      {:outputs, 0, :word, 0} => <<0x22, 0x33>>,
      {:markers, 0, :bit, 80} => <<0>>,
      {:markers, 0, :byte, 80} => <<0x33>>,
      {:markers, 0, :word, 80} => <<0x33, 0x44>>,
      {:markers, 0, :dword, 80} => <<0x33, 0x44, 0x55, 0x66>>
    }
  end

  defp receive_pdu(state) do
    case receive_tpkt(state) do
      {:ok, packet, state} ->
        {:ok, %Data{payload: payload, eot: true}} = COTP.decode(packet.payload)
        {:ok, pdu, <<>>} = PDU.decode(payload)
        {:ok, pdu, state}

      {:error, :closed} ->
        {:error, :closed}
    end
  end

  defp receive_tpkt(state) do
    case TPKT.decode(state.buffer) do
      {:ok, packet, remaining} ->
        {:ok, packet, %{state | buffer: remaining}}

      {:more, _needed} ->
        case :gen_tcp.recv(state.socket, 0, 2_000) do
          {:ok, bytes} -> receive_tpkt(%{state | buffer: state.buffer <> bytes})
          {:error, :closed} -> {:error, :closed}
        end
    end
  end

  defp send_pdu(state, pdu) do
    payload = pdu |> PDU.encode() |> IO.iodata_to_binary()

    if Keyword.get(state.options, :cotp_fragment_responses, false) and byte_size(payload) > 1 do
      split = div(byte_size(payload), 2)
      <<first::binary-size(split), second::binary>> = payload

      :ok = send_tpdu(state, %Data{payload: first, eot: false})
      send_tpdu(state, %Data{payload: second, tpdu_number: 1})
    else
      send_tpdu(state, %Data{payload: payload})
    end
  end

  defp send_tpdu(state, tpdu) do
    payload = tpdu |> COTP.encode() |> IO.iodata_to_binary()
    binary = %TPKT{payload: payload} |> TPKT.encode() |> IO.iodata_to_binary()

    if Keyword.get(state.options, :fragment_tcp, true) do
      send_fragmented(state.socket, binary)
    else
      :gen_tcp.send(state.socket, binary)
    end
  end

  defp send_fragmented(socket, binary) when byte_size(binary) <= 4,
    do: :gen_tcp.send(socket, binary)

  defp send_fragmented(socket, <<first::binary-size(2), second::binary-size(2), rest::binary>>) do
    with :ok <- :gen_tcp.send(socket, first),
         :ok <- pause(),
         :ok <- :gen_tcp.send(socket, second),
         :ok <- pause() do
      :gen_tcp.send(socket, rest)
    end
  end

  defp pause do
    Process.sleep(2)
    :ok
  end
end
