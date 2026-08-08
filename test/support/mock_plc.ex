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

    with {:ok, state} <- accept_cotp(state),
         {:ok, state} <- accept_setup(state) do
      serve(state)
    else
      {:stop, _state} -> :ok
    end
  end

  defp accept_cotp(state) do
    case receive_tpkt(state) do
      {:ok, packet, state} ->
        {:ok, %ConnectionRequest{} = request} = COTP.decode(packet.payload)
        send_cotp_response(state, request)
        {:ok, state}

      {:error, :closed} ->
        {:stop, state}
    end
  end

  defp send_cotp_response(%{options: options} = state, request) do
    confirm = %ConnectionConfirm{
      src_tsap: request.dst_tsap,
      dst_tsap: request.src_tsap,
      tpdu_size: request.tpdu_size,
      destination_reference: request.source_reference,
      source_reference: 1
    }

    case Keyword.get(options, :cotp_fault) do
      :wrong_reference ->
        send_tpdu(state, %{confirm | destination_reference: request.source_reference + 1})

      :unsupported_class ->
        send_tpdu(state, %{confirm | class_option: 1})

      :unexpected_tpdu ->
        send_tpdu(state, %Data{payload: <<>>})

      _other ->
        send_tpdu(state, confirm)
    end
  end

  defp accept_setup(state) do
    case receive_pdu(state) do
      {:ok, request, state} ->
        send_setup_response(state, request)
        {:ok, state}

      {:error, :closed} ->
        {:stop, state}
    end
  end

  defp send_setup_response(state, request) do
    {:ok, requested_setup} = SetupCommunication.decode(request.parameters)
    negotiated_pdu = Keyword.get(state.options, :negotiated_pdu, 240)

    response_setup = %SetupCommunication{
      max_amq_calling: min(requested_setup.max_amq_calling, 1),
      max_amq_called: min(requested_setup.max_amq_called, 1),
      pdu_length: min(requested_setup.pdu_length, negotiated_pdu)
    }

    success =
      PDU.new(:ack_data, request.header.pdu_reference, SetupCommunication.encode(response_setup))

    case Keyword.get(state.options, :setup_fault) do
      :wrong_reference ->
        send_pdu(state, put_in(success.header.pdu_reference, request.header.pdu_reference + 1))

      :header_error ->
        send_pdu(state, put_in(success.header.error_class, 0x81))

      :malformed_parameters ->
        send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<0xF0>>))

      :nonempty_data ->
        send_pdu(state, %{success | data: <<0>>})

      :unexpected_tpdu ->
        send_tpdu(state, %ConnectionConfirm{})

      :wrong_tpdu_number ->
        send_pdu_with_number(state, success, 1)

      :silence ->
        :ok

      _other ->
        send_pdu(state, success)
    end
  end

  defp serve(state) do
    case receive_pdu(state) do
      {:ok, %PDU{parameters: <<0x04, count, item_binary::binary>>} = request, state}
      when count > 0 ->
        {:ok, items, <<>>} = decode_request_items(item_binary, count, [])

        next_state =
          case items do
            [item] -> handle_read(state, request, Item.encode(item))
            items -> handle_read_many(state, request, items)
          end

        serve(next_state)

      {:ok, %PDU{parameters: <<0x05, count, item_binary::binary>>} = request, state}
      when count > 0 ->
        {:ok, items, <<>>} = decode_request_items(item_binary, count, [])

        next_state =
          case items do
            [item] -> handle_write(state, request, Item.encode(item))
            items -> handle_write_many(state, request, items)
          end

        serve(next_state)

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

  defp handle_read(%{read_fault: :trailing_pdu} = state, request, _item_binary) do
    response = successful_read_response(request, :word, <<0x04, 0xD2>>)
    payload = response |> PDU.encode() |> IO.iodata_to_binary()
    :ok = send_tpdu(state, %Data{payload: payload <> <<0>>})
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :truncated_pdu} = state, request, _item_binary) do
    response = successful_read_response(request, :word, <<0x04, 0xD2>>)
    payload = response |> PDU.encode() |> IO.iodata_to_binary()
    truncated_size = byte_size(payload) - 1
    <<truncated::binary-size(truncated_size), _last>> = payload
    :ok = send_tpdu(state, %Data{payload: truncated})
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :wrong_tpdu_number} = state, request, _item_binary) do
    response = successful_read_response(request, :word, <<0x04, 0xD2>>)
    :ok = send_pdu_with_number(state, response, 1)
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :unexpected_tpdu} = state, _request, _item_binary) do
    :ok = send_tpdu(state, %ConnectionConfirm{})
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :oversized_reassembly} = state, _request, _item_binary) do
    negotiated_pdu = Keyword.get(state.options, :negotiated_pdu, 240)
    :ok = send_tpdu(state, %Data{payload: :binary.copy(<<0>>, negotiated_pdu + 1)})
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :too_many_fragments} = state, _request, _item_binary) do
    for number <- 0..63 do
      :ok = send_tpdu(state, %Data{payload: <<>>, eot: false, tpdu_number: number})
    end

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

  defp handle_read_many(state, request, items) do
    encoded_items =
      Enum.map(items, fn item ->
        case Map.fetch(state.memory, memory_key(item)) do
          {:ok, data} ->
            data_item = %{DataItem.for_write(item.transport_size, data) | return_code: 0xFF}
            {DataItem.encode(data_item), byte_size(data)}

          :error ->
            {<<0x0A, 0, 0, 0>>, 0}
        end
      end)

    response =
      PDU.new(
        :ack_data,
        request.header.pdu_reference,
        <<0x04, length(items)>>,
        encode_aligned_data_items(encoded_items)
      )

    if Keyword.get(state.options, :read_fault) != :silence_multi do
      :ok = send_pdu(state, response)
    end

    state
  end

  defp handle_write(state, request, item_binary) do
    {:ok, item, <<>>} = Item.decode(item_binary)
    {:ok, data_item, <<>>} = DataItem.decode(request.data)

    case Keyword.get(state.options, :write_fault) do
      :plc_error ->
        response = PDU.new(:ack_data, request.header.pdu_reference, <<0x05, 1>>, <<0x05>>)
        :ok = send_pdu(state, response)
        state

      :malformed_response ->
        response = PDU.new(:ack_data, request.header.pdu_reference, <<0x05, 1>>, <<>>)
        :ok = send_pdu(state, response)
        state

      :wrong_reference ->
        response = PDU.new(:ack_data, request.header.pdu_reference + 1, <<0x05, 1>>, <<0xFF>>)
        :ok = send_pdu(state, response)
        state

      _other ->
        memory = Map.put(state.memory, memory_key(item), data_item.data)
        response = PDU.new(:ack_data, request.header.pdu_reference, <<0x05, 1>>, <<0xFF>>)
        :ok = send_pdu(state, response)
        %{state | memory: memory}
    end
  end

  defp handle_write_many(state, request, items) do
    {:ok, data_items, <<>>} = decode_write_data_items(request.data, items, [])

    memory =
      Enum.zip(items, data_items)
      |> Enum.reduce(state.memory, fn {item, data_item}, memory ->
        Map.put(memory, memory_key(item), data_item.data)
      end)

    unless Keyword.get(state.options, :write_fault) == :silence_multi do
      return_codes =
        case Keyword.get(state.options, :write_fault) do
          :second_item_error ->
            <<0xFF, 0x05, :binary.copy(<<0xFF>>, length(items) - 2)::binary>>

          _other ->
            :binary.copy(<<0xFF>>, length(items))
        end

      response =
        PDU.new(:ack_data, request.header.pdu_reference, <<0x05, length(items)>>, return_codes)

      :ok = send_pdu(state, response)
    end

    %{state | memory: memory}
  end

  defp decode_request_items(remaining, 0, items), do: {:ok, Enum.reverse(items), remaining}

  defp decode_request_items(binary, count, items) do
    with {:ok, item, remaining} <- Item.decode(binary) do
      decode_request_items(remaining, count - 1, [item | items])
    end
  end

  defp decode_write_data_items(remaining, [], items),
    do: {:ok, Enum.reverse(items), remaining}

  defp decode_write_data_items(data, [_item | items], decoded) do
    with {:ok, data_item, remaining} <- DataItem.decode(data),
         {:ok, remaining} <- consume_write_padding(remaining, data_item, items) do
      decode_write_data_items(remaining, items, [data_item | decoded])
    end
  end

  defp consume_write_padding(remaining, _data_item, []), do: {:ok, remaining}

  defp consume_write_padding(remaining, data_item, _items)
       when rem(byte_size(data_item.data), 2) == 0,
       do: {:ok, remaining}

  defp consume_write_padding(<<0, remaining::binary>>, _data_item, _items),
    do: {:ok, remaining}

  defp encode_aligned_data_items(items) do
    last_index = length(items) - 1

    items
    |> Enum.with_index()
    |> Enum.map(fn {{encoded, payload_size}, index} ->
      padding = if index < last_index and rem(payload_size, 2) == 1, do: <<0>>, else: <<>>
      [encoded, padding]
    end)
    |> IO.iodata_to_binary()
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

  defp send_pdu_with_number(state, pdu, number) do
    payload = pdu |> PDU.encode() |> IO.iodata_to_binary()
    send_tpdu(state, %Data{payload: payload, tpdu_number: number})
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
