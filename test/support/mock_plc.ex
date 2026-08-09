defmodule S7.Test.MockPLC do
  @moduledoc false

  import Bitwise

  alias S7.{Block, Connection, SessionPassword}

  alias S7.Protocol.{
    Alarm,
    BlockDownload,
    Clock,
    Cyclic,
    DataItem,
    Item,
    PDU,
    PIService,
    PLCControl,
    Programmer,
    Security,
    SetupCommunication,
    UserData
  }

  alias S7.Protocol.UserData.{Parameter, Payload}
  alias S7.Transport.{COTP, TPKT}

  alias S7.Transport.COTP.{
    ConnectionConfirm,
    ConnectionRequest,
    Data,
    DisconnectConfirm,
    DisconnectRequest,
    ErrorTPDU
  }

  defstruct [:pid, :port]

  def start_link(opts \\ []) do
    owner = self()
    port = Keyword.get(opts, :port, 0)

    {:ok, listener} =
      :gen_tcp.listen(port, [:binary, active: false, packet: :raw, reuseaddr: true])

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

    {:ok, security_password} =
      opts |> Keyword.get(:session_password, "TESTONLY") |> SessionPassword.new()

    state = %{
      socket: socket,
      owner: owner,
      buffer: <<>>,
      options: opts,
      read_fault: Keyword.get(opts, :read_fault),
      userdata_fault: Keyword.get(opts, :userdata_fault),
      szl_fault: Keyword.get(opts, :szl_fault),
      block_fault: Keyword.get(opts, :block_fault),
      clock_fault: Keyword.get(opts, :clock_fault),
      upload_fault: Keyword.get(opts, :upload_fault),
      download_fault: Keyword.get(opts, :download_fault),
      control_fault: Keyword.get(opts, :control_fault),
      programmer_fault: Keyword.get(opts, :programmer_fault),
      cyclic_fault: Keyword.get(opts, :cyclic_fault),
      alarm_fault: Keyword.get(opts, :alarm_fault),
      clock: Keyword.get(opts, :clock, ~N[2024-08-09 12:34:56.123]),
      security_password: Security.encode_password(security_password),
      authenticated: false,
      szl_pending: nil,
      block_pending: nil,
      upload_pending: nil,
      download_pending: nil,
      programmer_pending: nil,
      cyclic_jobs: %{},
      next_cyclic_job: 1,
      alarm_subscription: nil,
      deferred_reads: [],
      client_reference: nil,
      server_reference: 1,
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

        {:ok,
         %{
           state
           | client_reference: request.source_reference,
             server_reference: 1
         }}

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

      {:error, :closed, _state} ->
        {:stop, state}
    end
  end

  defp send_setup_response(state, request) do
    {:ok, requested_setup} = SetupCommunication.decode(request.parameters)
    negotiated_pdu = Keyword.get(state.options, :negotiated_pdu, 240)
    negotiated_jobs = Keyword.get(state.options, :negotiated_jobs, 1)

    response_setup = %SetupCommunication{
      max_amq_calling: min(requested_setup.max_amq_calling, negotiated_jobs),
      max_amq_called: min(requested_setup.max_amq_called, negotiated_jobs),
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

  defp serve(state), do: state |> receive_pdu() |> handle_received()

  defp handle_received({:cotp, %DisconnectRequest{} = request, state}),
    do: handle_disconnect_request(state, request)

  defp handle_received({:cotp, %DisconnectConfirm{} = confirm, state}) do
    send(state.owner, {:mock_plc_disconnect_confirm, confirm})
    close_server_socket(state)
  end

  defp handle_received({:cotp, %ErrorTPDU{} = error, state}) do
    send(state.owner, {:mock_plc_error_tpdu, error})
    close_server_socket(state)
  end

  defp handle_received({:ok, %PDU{header: %{rosctr: :userdata}} = request_pdu, state}) do
    {:ok, request} = UserData.from_pdu(request_pdu)
    state |> handle_userdata(request_pdu, request) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{header: %{rosctr: :job}, parameters: <<0x1A, _rest::binary>>} = request,
          state}
       ) do
    state |> handle_download_start(request) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{header: %{rosctr: :ack_data}, parameters: <<0x1B, _status>>} = response,
          state}
       ) do
    state |> handle_download_response(response) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{header: %{rosctr: :ack_data}, parameters: <<0x1C>>} = response, state}
       ) do
    state |> handle_download_end_response(response) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{header: %{rosctr: :job}, parameters: <<0x28, _rest::binary>>} = request,
          state}
       ) do
    state |> handle_pi_service(request) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{header: %{rosctr: :job}, parameters: <<0x29, _rest::binary>>} = request,
          state}
       ) do
    state |> handle_control(request) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{header: %{rosctr: :job}, parameters: <<0xEE, 0x01>>} = request, state}
       ) do
    count = Keyword.get(state.options, :transaction_jobs, 1)

    Enum.each(1..count, fn sequence ->
      job = PDU.new(:job, 0x7000 + sequence, <<0xEE, 0x02, sequence>>, <<sequence>>)
      :ok = send_pdu(state, job)
    end)

    response =
      PDU.new(
        :ack_data,
        request.header.pdu_reference,
        <<0xEE, 0x01>>,
        "transaction-response"
      )

    :ok = send_pdu(state, response)
    state |> notify_request(:transaction, request) |> serve()
  end

  defp handle_received(
         {:ok,
          %PDU{
            header: %{rosctr: :job},
            parameters: <<0x1D, 0, 0::16, 0::32, 9, filename::binary-size(9)>>,
            data: <<>>
          } = request, state}
       ) do
    state |> handle_upload_start(request, filename) |> serve()
  end

  defp handle_received(
         {:ok,
          %PDU{
            header: %{rosctr: :job},
            parameters: <<0x1E, 0, 0::16, upload_id::unsigned-big-32>>,
            data: <<>>
          } = request, state}
       ) do
    state |> handle_upload_segment(request, upload_id) |> serve()
  end

  defp handle_received(
         {:ok,
          %PDU{
            header: %{rosctr: :job},
            parameters: <<0x1F, 0, _error::16, upload_id::unsigned-big-32>>,
            data: <<>>
          } = request, state}
       ) do
    state |> handle_upload_end(request, upload_id) |> serve()
  end

  defp handle_received(
         {:ok,
          %PDU{header: %{rosctr: rosctr, pdu_reference: reference}, parameters: <<0xEE, 0x03>>},
          state}
       )
       when rosctr in [:ack, :ack_data] do
    send(state.owner, {:mock_plc_transaction_reply, reference})
    serve(state)
  end

  defp handle_received(
         {:ok, %PDU{parameters: <<0x04, count, item_binary::binary>>} = request, state}
       )
       when count > 0 do
    {:ok, items, <<>>} = decode_request_items(item_binary, count, [])
    state = notify_request(state, :read, request)
    state |> handle_read_items(request, items) |> serve()
  end

  defp handle_received(
         {:ok, %PDU{parameters: <<0x05, count, item_binary::binary>>} = request, state}
       )
       when count > 0 do
    {:ok, items, <<>>} = decode_request_items(item_binary, count, [])
    state = notify_request(state, :write, request)
    state |> handle_write_items(request, items) |> serve()
  end

  defp handle_received({:error, :closed, state}), do: close_server_socket(state, false)

  defp handle_upload_start(state, request, filename) do
    state = notify_request(state, :upload_start, request)

    with {:ok, block} <- decode_upload_filename(filename),
         {:ok, image} <- upload_image(state, block) do
      case state.upload_fault do
        :start_rejected ->
          send_upload_header_error(%{state | upload_fault: nil}, request, 0xD241)

        :malformed_start ->
          response = PDU.new(:ack_data, request.header.pdu_reference, <<0x1D, 0>>)
          :ok = send_pdu(state, response)
          %{state | upload_fault: nil}

        _other ->
          upload_id = Keyword.get(state.options, :upload_id, 7)
          advertised_size = advertised_upload_size(state, image)
          size = advertised_size |> Integer.to_string() |> String.pad_leading(7, "0")

          response =
            PDU.new(
              :ack_data,
              request.header.pdu_reference,
              <<0x1D, 0, 0x0100::16, upload_id::unsigned-big-32, byte_size(size), size::binary>>
            )

          :ok = send_pdu(state, response)

          %{
            state
            | upload_pending: %{id: upload_id, image: image, offset: 0, block: block}
          }
      end
    else
      :error -> send_upload_header_error(state, request, 0xD209)
    end
  end

  defp handle_download_start(state, request) do
    state = notify_request(state, :download_start, request)

    case BlockDownload.decode_start_request(request, :mock_download) do
      {:ok, start} -> start_download(state, request, start)
      {:error, _error} -> send_upload_header_error(state, request, 0xD20C)
    end
  end

  defp start_download(%{download_fault: :start_rejected} = state, request, _start) do
    send_upload_header_error(%{state | download_fault: nil}, request, 0xD241)
  end

  defp start_download(%{download_fault: :malformed_start_response} = state, request, start) do
    :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<0x1A, 0>>))
    %{state | download_fault: nil, download_pending: new_download_pending(start)}
  end

  defp start_download(state, request, start) do
    expected_block = Keyword.get(state.options, :expected_download_block, start.block)
    expected_image = Keyword.get(state.options, :expected_download_image)

    valid_image? =
      is_nil(expected_image) or
        (is_binary(expected_image) and byte_size(expected_image) == start.load_memory_size)

    if expected_block == start.block and valid_image? do
      :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<0x1A>>))
      state = %{state | download_pending: new_download_pending(start)}
      begin_download_pull(state)
    else
      send_upload_header_error(state, request, 0xD20C)
    end
  end

  defp begin_download_pull(%{download_fault: :segment_silence} = state),
    do: %{state | download_fault: nil}

  defp begin_download_pull(%{download_fault: :segment_disconnect} = state) do
    :ok = :gen_tcp.close(state.socket)
    %{state | download_fault: nil}
  end

  defp begin_download_pull(state), do: send_download_job(state)

  defp send_download_job(%{download_pending: pending} = state) do
    Process.sleep(Keyword.get(state.options, :download_response_delay, 0))
    reference = pending.next_reference

    block =
      if state.download_fault == :wrong_download_identity do
        %{pending.block | number: pending.block.number + 1}
      else
        pending.block
      end

    parameters =
      if state.download_fault == :malformed_download_job do
        <<0x1B, 0>>
      else
        filename = Block.encode_filename(block, :passive)
        <<0x1B, 0, 0::16, 0::32, 9, filename::binary>>
      end

    _result = send_pdu(state, PDU.new(:job, reference, parameters))
    state = notify_request(state, :download_pull, %{header: %{pdu_reference: reference}})

    fault =
      if state.download_fault in [:wrong_download_identity, :malformed_download_job],
        do: nil,
        else: state.download_fault

    pending = %{pending | outstanding_reference: reference, next_reference: reference + 1}
    %{state | download_fault: fault, download_pending: pending}
  end

  defp handle_download_response(%{download_pending: pending} = state, response) do
    state = notify_request(state, :download_segment, response)

    with true <- response.header.pdu_reference == pending.outstanding_reference,
         {:ok, decoded} <- BlockDownload.decode_download_response(response, :mock_download),
         true <- pending.received_size + byte_size(decoded.data) <= pending.load_memory_size do
      pending = %{
        pending
        | parts: [decoded.data | pending.parts],
          received_size: pending.received_size + byte_size(decoded.data),
          outstanding_reference: nil
      }

      continue_download_response(%{state | download_pending: pending}, decoded.more?)
    else
      _other ->
        :ok = :gen_tcp.close(state.socket)
        state
    end
  end

  defp continue_download_response(%{download_pending: pending} = state, true)
       when pending.received_size < pending.load_memory_size do
    send_download_job(state)
  end

  defp continue_download_response(%{download_pending: pending} = state, false)
       when pending.received_size == pending.load_memory_size do
    send_download_end_job(state)
  end

  defp continue_download_response(state, _more?) do
    :ok = :gen_tcp.close(state.socket)
    state
  end

  defp send_download_end_job(%{download_pending: pending} = state) do
    reference = pending.next_reference
    filename = Block.encode_filename(pending.block, :passive)
    error_code = if state.download_fault == :download_end_rejected, do: 0xD241, else: 0

    parameters =
      if state.download_fault == :malformed_download_end do
        <<0x1C, 0>>
      else
        <<0x1C, 0, error_code::16, 0::32, 9, filename::binary>>
      end

    :ok = send_pdu(state, PDU.new(:job, reference, parameters))
    state = notify_request(state, :download_end, %{header: %{pdu_reference: reference}})
    pending = %{pending | outstanding_reference: reference, stage: :download_ended}
    %{state | download_pending: pending}
  end

  defp handle_download_end_response(%{download_pending: pending} = state, response) do
    with true <- pending.stage == :download_ended,
         true <- response.header.pdu_reference == pending.outstanding_reference,
         :ok <- BlockDownload.decode_end_response(response, :mock_download) do
      raw = pending.parts |> Enum.reverse() |> IO.iodata_to_binary()
      send(state.owner, {:mock_plc_downloaded, pending.block, raw})
      pending = %{pending | image: raw, stage: :activation, outstanding_reference: nil}
      %{state | download_pending: pending}
    else
      _other ->
        :ok = :gen_tcp.close(state.socket)
        state
    end
  end

  defp handle_pi_service(state, request) do
    case PLCControl.decode_request(request, :mock_control) do
      {:ok, _action} ->
        handle_control(state, request)

      {:error, _error} ->
        case PIService.decode_block_request(request, :mock_pi_service) do
          {:ok, %{action: :insert, block: block}} -> handle_block_insert(state, request, block)
          {:ok, %{action: :delete, block: block}} -> handle_block_delete(state, request, block)
          {:error, _error} -> send_upload_header_error(state, request, 0xD20C)
        end
    end
  end

  defp handle_control(state, request) do
    case PLCControl.decode_request(request, :mock_control) do
      {:ok, action} -> send_control_response(state, request, action)
      {:error, _error} -> send_upload_header_error(state, request, 0xD20C)
    end
  end

  defp send_control_response(state, request, action) do
    state = notify_request(state, action, request)
    Process.sleep(Keyword.get(state.options, :control_response_delay, 0))

    case state.control_fault do
      :rejected ->
        send_upload_header_error(%{state | control_fault: nil}, request, 0xD241)

      :malformed_response ->
        function = if action == :stop_cpu, do: 0x28, else: 0x29
        :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<function>>))
        %{state | control_fault: nil}

      :disconnect ->
        :ok = :gen_tcp.close(state.socket)
        %{state | control_fault: nil}

      :silence ->
        %{state | control_fault: nil}

      _other ->
        function = if action == :stop_cpu, do: 0x29, else: 0x28
        :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<function>>))
        send(state.owner, {:mock_plc_controlled, action})
        state
    end
  end

  defp handle_block_insert(
         %{download_pending: %{stage: :activation, block: block} = pending} = state,
         request,
         block
       ) do
    state = notify_request(state, :insert_block, request)

    case state.download_fault do
      :insert_rejected ->
        state
        |> Map.put(:download_pending, nil)
        |> Map.put(:download_fault, nil)
        |> send_upload_header_error(request, 0xD241)

      :malformed_insert_response ->
        :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<0x28, 0>>))
        %{state | download_pending: nil, download_fault: nil}

      :insert_disconnect ->
        :ok = :gen_tcp.close(state.socket)
        %{state | download_pending: nil, download_fault: nil}

      _other ->
        :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<0x28>>))
        send(state.owner, {:mock_plc_block_activated, block, pending.image})
        %{state | download_pending: nil, download_fault: nil}
    end
  end

  defp handle_block_insert(state, request, _block),
    do: send_upload_header_error(state, request, 0xD20C)

  defp handle_block_delete(state, request, block) do
    state = notify_request(state, :delete_block, request)

    if state.download_fault == :delete_rejected do
      send_upload_header_error(%{state | download_fault: nil}, request, 0xD241)
    else
      :ok = send_pdu(state, PDU.new(:ack_data, request.header.pdu_reference, <<0x28>>))
      send(state.owner, {:mock_plc_block_deleted, block})
      state
    end
  end

  defp new_download_pending(start) do
    %{
      block: start.block,
      load_memory_size: start.load_memory_size,
      mc7_size: start.mc7_size,
      received_size: 0,
      parts: [],
      stage: :download,
      next_reference: 0x6501,
      outstanding_reference: nil,
      image: nil
    }
  end

  defp handle_upload_segment(
         %{upload_pending: %{id: upload_id} = pending} = state,
         request,
         upload_id
       ) do
    state = notify_request(state, :upload_segment, request)
    Process.sleep(Keyword.get(state.options, :upload_response_delay, 0))

    case state.upload_fault do
      :segment_header_error ->
        send_upload_header_error(%{state | upload_fault: nil}, request, 0xD241)

      :segment_disconnect ->
        :ok = :gen_tcp.close(state.socket)
        %{state | upload_fault: nil}

      :segment_silence ->
        %{state | upload_fault: nil}

      _other ->
        send_upload_segment(state, request, pending)
    end
  end

  defp handle_upload_segment(state, request, _upload_id),
    do: send_upload_header_error(state, request, 0xD209)

  defp send_upload_segment(state, request, pending) do
    remaining_size = byte_size(pending.image) - pending.offset
    configured_size = Keyword.get(state.options, :upload_chunk_size, remaining_size)
    chunk_size = min(configured_size, remaining_size)
    chunk = binary_part(pending.image, pending.offset, chunk_size)
    offset = pending.offset + chunk_size
    more? = offset < byte_size(pending.image) or state.upload_fault == :endless_segments
    status = if more?, do: 1, else: 0
    marker = if state.upload_fault == :malformed_segment, do: 0x00FA, else: 0x00FB

    response =
      PDU.new(
        :ack_data,
        request.header.pdu_reference,
        <<0x1E, status>>,
        <<byte_size(chunk)::unsigned-big-16, marker::unsigned-big-16, chunk::binary>>
      )

    :ok = send_pdu(state, response)

    state =
      if state.upload_fault == :malformed_segment,
        do: %{state | upload_fault: nil},
        else: state

    %{state | upload_pending: %{pending | offset: offset}}
  end

  defp handle_upload_end(
         %{upload_pending: %{id: upload_id}} = state,
         request,
         upload_id
       ) do
    state = notify_request(state, :upload_end, request)

    response =
      if state.upload_fault == :malformed_end do
        PDU.new(:ack_data, request.header.pdu_reference, <<0x1F, 0>>)
      else
        PDU.new(:ack_data, request.header.pdu_reference, <<0x1F>>)
      end

    :ok = send_pdu(state, response)
    %{state | upload_pending: nil, upload_fault: nil}
  end

  defp handle_upload_end(state, request, _upload_id),
    do: send_upload_header_error(state, request, 0xD209)

  defp send_upload_header_error(state, request, code) do
    response =
      PDU.new(:ack, request.header.pdu_reference, <<>>, <<>>,
        error_class: code >>> 8,
        error_code: code &&& 0xFF
      )

    :ok = send_pdu(state, response)
    state
  end

  defp decode_upload_filename(<<"_", type_code::unsigned-big-16, number::binary-size(5), "A">>) do
    case {Block.decode_type(type_code), Integer.parse(number)} do
      {type, {number, ""}} when is_atom(type) and number in 0..0xFFFF ->
        {:ok, %Block{type: type, number: number}}

      _other ->
        :error
    end
  end

  defp upload_image(state, block) do
    expected = Keyword.get(state.options, :upload_block, block)
    image = Keyword.get(state.options, :upload_image)

    if expected == block and is_binary(image) and byte_size(image) > 0,
      do: {:ok, image},
      else: :error
  end

  defp advertised_upload_size(state, image) do
    case state.upload_fault do
      :wrong_advertised_size -> byte_size(image) + 1
      _other -> Keyword.get(state.options, :upload_advertised_size, byte_size(image))
    end
  end

  defp handle_read_items(state, request, [item]),
    do: handle_read(state, request, Item.encode(item))

  defp handle_read_items(state, request, items), do: handle_read_many(state, request, items)

  defp handle_write_items(state, request, [item]),
    do: handle_write(state, request, Item.encode(item))

  defp handle_write_items(state, request, items), do: handle_write_many(state, request, items)

  defp close_server_socket(state, close? \\ true) do
    if close?, do: :ok = :gen_tcp.close(state.socket)
    send(state.owner, :mock_plc_closed)
    :ok
  end

  defp handle_disconnect_request(state, request) do
    send(state.owner, {:mock_plc_disconnect_request, request})

    case Keyword.get(state.options, :disconnect_behavior, :confirm) do
      :confirm ->
        confirm = %DisconnectConfirm{
          destination_reference: request.source_reference,
          source_reference: request.destination_reference
        }

        :ok = send_tpdu(state, confirm)
        close_server_socket(state)

      :invalid_confirm ->
        confirm = %DisconnectConfirm{
          destination_reference: request.source_reference + 1,
          source_reference: request.destination_reference
        }

        :ok = send_tpdu(state, confirm)
        await_client_close(state)

      :fin ->
        close_server_socket(state)

      :error ->
        :ok = send_tpdu(state, %ErrorTPDU{destination_reference: request.source_reference})
        await_client_close(state)

      :silence ->
        await_client_close(state)
    end
  end

  defp await_client_close(state) do
    case :gen_tcp.recv(state.socket, 0, 2_000) do
      {:error, :closed} ->
        send(state.owner, :mock_plc_closed)
        :ok

      {:ok, _bytes} ->
        await_client_close(state)
    end
  end

  defp handle_userdata(
         %{userdata_fault: :indication_before_response} = state,
         request_pdu,
         request
       ) do
    count = Keyword.get(state.options, :indication_count, 1)

    Enum.each(1..count, fn sequence ->
      indication = %UserData{
        parameter: %Parameter{
          method: 0x12,
          type: :indication,
          function_group: :cpu,
          subfunction: 3,
          sequence: sequence
        },
        payload: %Payload{data: "event#{sequence}"}
      }

      {:ok, indication_pdu} = UserData.to_pdu(indication, 0)
      :ok = send_pdu(state, indication_pdu)
    end)

    send_userdata_response(%{state | userdata_fault: nil}, request_pdu, request)
  end

  defp handle_userdata(%{userdata_fault: :parameter_error} = state, request_pdu, request) do
    send_userdata_response(%{state | userdata_fault: nil}, request_pdu, request,
      error_code: 0xD041
    )
  end

  defp handle_userdata(%{userdata_fault: :wrong_service} = state, request_pdu, request) do
    send_userdata_response(%{state | userdata_fault: nil}, request_pdu, request,
      subfunction: request.parameter.subfunction + 1
    )
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{parameter: %Parameter{function_group: :cyclic}} = request
       ) do
    case Cyclic.decode_request(request, :mock_cyclic) do
      {:ok, %{action: :subscribe} = decoded} ->
        handle_cyclic_subscribe(state, request_pdu, request, decoded)

      {:ok, %{action: :modify} = decoded} ->
        handle_cyclic_modify(state, request_pdu, request, decoded)

      {:ok, %{action: :unsubscribe} = decoded} ->
        handle_cyclic_unsubscribe(state, request_pdu, request, decoded)

      {:error, _error} ->
        send_userdata_response(state, request_pdu, request,
          error_code: 0xD20C,
          data: <<>>
        )
    end
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x11,
             type: :request,
             function_group: :cpu,
             subfunction: subfunction
           }
         } = request
       )
       when subfunction in [0x02, 0x0B, 0x13] do
    case Alarm.decode_request(request, :mock_alarm) do
      {:ok, %{action: :subscribe} = decoded} ->
        handle_alarm_subscribe(state, request_pdu, request, decoded)

      {:ok, %{action: :unsubscribe} = decoded} ->
        handle_alarm_unsubscribe(state, request_pdu, request, decoded)

      {:ok, %{action: :query} = decoded} ->
        handle_alarm_query(state, request_pdu, request, decoded)

      {:ok, %{action: :acknowledge} = decoded} ->
        handle_alarm_acknowledgement(state, request_pdu, request, decoded)

      {:error, _error} ->
        send_userdata_response(state, request_pdu, request,
          error_code: 0xD20C,
          data: <<>>
        )
    end
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x12,
             type: :request,
             function_group: :programmer,
             subfunction: subfunction
           },
           payload: %Payload{data: service_data}
         } = request
       )
       when subfunction in [0x01, 0x02, 0x03, 0x04, 0x05, 0x10, 0x11, 0x13] do
    state = notify_request(state, :programmer_setup, request_pdu)

    case state.programmer_fault do
      :setup_rejected ->
        send_userdata_response(%{state | programmer_fault: nil}, request_pdu, request,
          sequence: 2,
          error_code: 0xD241,
          return_code: 0x0A,
          transport_size: 0,
          data: <<>>
        )

      :malformed_setup ->
        send_userdata_response(%{state | programmer_fault: nil}, request_pdu, request,
          sequence: 2,
          data: <<>>
        )

      _other ->
        {:ok, setup_parameters, setup_data} =
          Programmer.decode_service_data(service_data, :programmer_diagnostic)

        pending = %{
          subfunction: subfunction,
          sequence: 2,
          setup_parameters: setup_parameters,
          setup_data: setup_data
        }

        send_userdata_response(%{state | programmer_pending: pending}, request_pdu, request,
          sequence: 2,
          return_code: 0x0A,
          transport_size: 0,
          data: <<>>
        )
    end
  end

  defp handle_userdata(
         %{programmer_pending: %{subfunction: subfunction, sequence: sequence}} = state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x12,
             type: :request,
             function_group: :programmer,
             subfunction: 0x0E
           },
           payload: %Payload{data: service_data}
         } = request
       ) do
    {:ok, _parameters, <<^subfunction, ^sequence>>} =
      Programmer.decode_service_data(service_data, :programmer_diagnostic)

    state = notify_request(state, :programmer_enable, request_pdu)

    state =
      send_userdata_response(state, request_pdu, request,
        sequence: 3,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )

    Process.sleep(Keyword.get(state.options, :programmer_indication_delay, 0))
    send_programmer_indication(state)
  end

  defp handle_userdata(
         %{programmer_pending: %{subfunction: subfunction, sequence: sequence}} = state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x12,
             type: :request,
             function_group: :programmer,
             subfunction: 0x0F
           },
           payload: %Payload{data: service_data}
         } = request
       ) do
    {:ok, _parameters, <<1::16, ^subfunction, ^sequence>>} =
      Programmer.decode_service_data(service_data, :programmer_diagnostic)

    state = notify_request(state, :programmer_delete, request_pdu)

    if state.programmer_fault == :delete_rejected do
      send_userdata_response(state, request_pdu, request,
        sequence: 4,
        error_code: 0xD241,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )
    else
      send_userdata_response(%{state | programmer_pending: nil}, request_pdu, request,
        sequence: 4,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )
    end
  end

  defp handle_userdata(
         %{clock_fault: :malformed_timestamp} = state,
         request_pdu,
         %UserData{parameter: %Parameter{function_group: :time, subfunction: 1}} = request
       ) do
    state = notify_request(%{state | clock_fault: nil}, :read_clock, request_pdu)
    send_userdata_response(state, request_pdu, request, data: <<0::80>>)
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{parameter: %Parameter{function_group: :time, subfunction: 1}} = request
       ) do
    {:ok, timestamp} = Clock.encode_timestamp(state.clock)
    state = notify_request(state, :read_clock, request_pdu)
    send_userdata_response(state, request_pdu, request, data: timestamp)
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{function_group: :time, subfunction: 2},
           payload: %Payload{data: timestamp}
         } = request
       ) do
    {:ok, clock} = Clock.decode_timestamp(timestamp)
    state = notify_request(%{state | clock: clock.datetime}, :set_clock, request_pdu)

    send_userdata_response(state, request_pdu, request,
      return_code: 0x0A,
      transport_size: 0,
      data: <<>>
    )
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{function_group: :security, subfunction: 1},
           payload: %Payload{data: encoded_password}
         } = request
       ) do
    state = notify_request(state, :authenticate, request_pdu)
    Process.sleep(Keyword.get(state.options, :security_response_delay, 0))

    if encoded_password == state.security_password do
      send_userdata_response(%{state | authenticated: true}, request_pdu, request,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )
    else
      send_userdata_response(%{state | authenticated: false}, request_pdu, request,
        error_code: 0xD602,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )
    end
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{parameter: %Parameter{function_group: :security, subfunction: 2}} = request
       ) do
    state = notify_request(state, :logout, request_pdu)

    if state.authenticated do
      send_userdata_response(%{state | authenticated: false}, request_pdu, request,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )
    else
      send_userdata_response(state, request_pdu, request,
        error_code: 0xD604,
        return_code: 0x0A,
        transport_size: 0,
        data: <<>>
      )
    end
  end

  defp handle_userdata(
         %{block_pending: %{sequence: sequence}} = state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x12,
             type: :request,
             function_group: :blocks,
             subfunction: 2,
             sequence: sequence
           },
           payload: %Payload{return_code: 0x0A, transport_size: 0, data: <<>>}
         }
       ) do
    continue_block_list(state, request_pdu)
  end

  defp handle_userdata(
         %{block_fault: :malformed_geometry} = state,
         request_pdu,
         %UserData{
           parameter: %Parameter{type: :request, function_group: :blocks, subfunction: 2}
         }
       ) do
    send_block_response(%{state | block_fault: nil}, request_pdu, 2, <<0, 1, 5>>)
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{type: :request, function_group: :blocks, subfunction: 1}
         }
       ) do
    data =
      <<0x3038::16, 1::16, 0x3045::16, 1::16, 0x3043::16, 0::16, 0x3041::16, 2::16, 0x3042::16,
        8::16, 0x3044::16, 77::16, 0x3046::16, 15::16>>

    send_block_response(state, request_pdu, 1, data)
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{type: :request, function_group: :blocks, subfunction: 2},
           payload: %Payload{data: <<type_code::unsigned-big-16>>}
         }
       ) do
    type = Block.decode_type(type_code)

    records =
      state.options
      |> Keyword.get(:block_entries, default_block_entries())
      |> Map.get(type, [])
      |> Enum.map(fn {number, flags, language} -> <<number::16, flags, language>> end)

    chunk_size = Keyword.get(state.options, :block_fragment_entries, max(length(records), 1))
    chunks = records |> Enum.chunk_every(chunk_size) |> Enum.map(&IO.iodata_to_binary/1)
    chunks = if chunks == [], do: [<<>>], else: chunks
    [chunk | remaining] = chunks
    sequence = 1
    data_unit_reference = 0xE1

    state =
      if remaining == [] do
        %{state | block_pending: nil}
      else
        %{
          state
          | block_pending: %{
              chunks: remaining,
              sequence: sequence,
              data_unit_reference: data_unit_reference
            }
        }
      end

    send_block_response(state, request_pdu, 2, chunk,
      sequence: sequence,
      data_unit_reference: data_unit_reference,
      more?: remaining != []
    )
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{type: :request, function_group: :blocks, subfunction: 3},
           payload: %Payload{data: <<0x3041::16, "00001", "A">>}
         }
       ) do
    send_block_response(state, request_pdu, 3, block_info_data())
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{type: :request, function_group: :blocks, subfunction: 3}
         }
       ) do
    send_block_response(state, request_pdu, 3, <<>>, error_code: 0xD209)
  end

  defp handle_userdata(
         state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x11,
             type: :request,
             function_group: :cpu,
             subfunction: 1
           },
           payload: %Payload{data: <<id::unsigned-big-16, index::unsigned-big-16>>}
         }
       ) do
    start_szl_response(state, request_pdu, id, index)
  end

  defp handle_userdata(
         %{szl_pending: %{sequence: sequence}} = state,
         request_pdu,
         %UserData{
           parameter: %Parameter{
             method: 0x12,
             type: :request,
             function_group: :cpu,
             subfunction: 1,
             sequence: sequence
           },
           payload: %Payload{data: <<>>}
         }
       ) do
    continue_szl_response(state, request_pdu)
  end

  defp handle_userdata(state, request_pdu, request),
    do: send_userdata_response(state, request_pdu, request)

  defp continue_block_list(
         %{block_pending: %{chunks: [chunk | remaining]} = pending} = state,
         request_pdu
       ) do
    state = %{
      state
      | block_pending: if(remaining == [], do: nil, else: %{pending | chunks: remaining})
    }

    send_block_response(state, request_pdu, 2, chunk,
      sequence: pending.sequence,
      data_unit_reference: pending.data_unit_reference,
      more?: remaining != []
    )
  end

  defp send_block_response(state, request_pdu, subfunction, data, opts \\ []) do
    response = %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :response,
        function_group: :blocks,
        subfunction: subfunction,
        sequence: Keyword.get(opts, :sequence, 0),
        data_unit_reference: Keyword.get(opts, :data_unit_reference, 0),
        last_data_unit: if(Keyword.get(opts, :more?, false), do: 1, else: 0),
        error_code: Keyword.get(opts, :error_code, 0)
      },
      payload: %Payload{transport_size: 9, data: data}
    }

    {:ok, response_pdu} = UserData.to_pdu(response, request_pdu.header.pdu_reference)
    :ok = send_pdu(state, response_pdu)
    state
  end

  defp default_block_entries do
    %{
      db: [{1, 0x22, 0x05}, {2, 0x22, 0x05}],
      ob: [{1, 0x22, 0x01}],
      sfc: Enum.map(0..9, &{&1, 0x42, 0x01})
    }
  end

  defp block_info_data do
    Base.decode16!(
      "0100004A220070700101050A0001000000660000000304EF14B02D9701CB655011FC001400000000000A53494D41544943004945435F5443000043545500000000001000798C0000000000000000"
    )
  end

  defp start_szl_response(state, request_pdu, id, index) do
    case Map.fetch(szl_data(state), {id, index}) do
      {:ok, {record_length, records}} ->
        raw = encode_szl(record_length, records, state.szl_fault)
        chunks = split_szl(raw, Keyword.get(state.options, :szl_fragment_size, byte_size(raw)))
        [chunk | remaining] = chunks
        sequence = 0x2A
        data_unit_reference = 7
        response_id = if state.szl_fault == :mismatched_id, do: Bitwise.bxor(id, 1), else: id
        payload = <<response_id::16, index::16, chunk::binary>>

        pending =
          if remaining == [] do
            nil
          else
            %{
              chunks: remaining,
              sequence: sequence,
              data_unit_reference: data_unit_reference
            }
          end

        state =
          if state.szl_fault == :mismatched_id,
            do: %{state | szl_fault: nil, szl_pending: pending},
            else: %{state | szl_pending: pending}

        send_szl_fragment(
          state,
          request_pdu,
          payload,
          remaining != [],
          sequence,
          data_unit_reference
        )

      :error ->
        send_userdata_response(state, request_pdu, szl_request(id, index), error_code: 0x02D4)
    end
  end

  defp continue_szl_response(
         %{szl_pending: %{chunks: [chunk | remaining]} = pending} = state,
         request_pdu
       ) do
    data_unit_reference =
      if state.szl_fault == :mismatched_data_unit_reference do
        pending.data_unit_reference + 1
      else
        pending.data_unit_reference
      end

    next_pending = if remaining == [], do: nil, else: %{pending | chunks: remaining}

    state =
      if state.szl_fault == :mismatched_data_unit_reference,
        do: %{state | szl_fault: nil, szl_pending: next_pending},
        else: %{state | szl_pending: next_pending}

    send_szl_fragment(
      state,
      request_pdu,
      chunk,
      remaining != [],
      pending.sequence,
      data_unit_reference
    )
  end

  defp send_szl_fragment(
         state,
         request_pdu,
         data,
         more?,
         sequence,
         data_unit_reference
       ) do
    parameter =
      if state.szl_fault == :missing_extension do
        %Parameter{
          method: 0x12,
          type: :response,
          function_group: :cpu,
          subfunction: 1,
          sequence: sequence
        }
      else
        %Parameter{
          method: 0x12,
          type: :response,
          function_group: :cpu,
          subfunction: 1,
          sequence: sequence,
          data_unit_reference: data_unit_reference,
          last_data_unit: if(more?, do: 1, else: 0),
          error_code: 0
        }
      end

    transport_size = if state.szl_fault == :wrong_transport, do: 0x04, else: 0x09

    response = %UserData{
      parameter: parameter,
      payload: %Payload{transport_size: transport_size, data: data}
    }

    {:ok, response_pdu} = UserData.to_pdu(response, request_pdu.header.pdu_reference)
    :ok = send_pdu(state, response_pdu)

    if state.szl_fault in [:missing_extension, :wrong_transport],
      do: %{state | szl_fault: nil},
      else: state
  end

  defp szl_request(id, index) do
    {:ok, request} = UserData.request(:cpu, 1, <<id::16, index::16>>)
    request
  end

  defp encode_szl(record_length, records, :malformed_geometry) do
    [<<record_length::16, length(records) + 1::16>>, records]
    |> IO.iodata_to_binary()
  end

  defp encode_szl(record_length, records, _fault) do
    [<<record_length::16, length(records)::16>>, records]
    |> IO.iodata_to_binary()
  end

  defp split_szl(binary, size) when is_integer(size) and size > 0 do
    do_split_szl(binary, size, [])
  end

  defp do_split_szl(<<>>, _size, chunks), do: Enum.reverse(chunks)

  defp do_split_szl(binary, size, chunks) when byte_size(binary) <= size,
    do: Enum.reverse([binary | chunks])

  defp do_split_szl(binary, size, chunks) do
    <<chunk::binary-size(size), remaining::binary>> = binary
    do_split_szl(remaining, size, [chunk | chunks])
  end

  defp szl_data(state), do: Keyword.get(state.options, :szl_data, default_szl_data())

  defp default_szl_data do
    order_record =
      <<1::16, fixed_text("6ES7 315-2EH14-0AB0", 20)::binary, 0::16, 3::16, 2::8, 1::8>>

    component_records = [
      component_record(1, "Test PLC"),
      component_record(2, "CPU 315-2 PN/DP"),
      component_record(4, "Original Siemens Equipment"),
      component_record(5, "S C-C2UR28922012"),
      component_record(7, "CPU 315-2 PN/DP")
    ]

    %{
      {0x0000, 0} => {2, Enum.map([0x0011, 0x001C, 0x0131, 0x0424], &<<&1::unsigned-big-16>>)},
      {0x0011, 0} => {28, [order_record]},
      {0x001C, 0} => {34, component_records},
      {0x0131, 1} => {14, [<<1::16, 480::16, 8::16, 187_500::32, 12_000_000::32>>]},
      {0x0424, 0} => {4, [<<0::16, 0, 8>>]}
    }
  end

  defp component_record(index, text), do: <<index::16, fixed_text(text, 32)::binary>>

  defp fixed_text(text, size) do
    padded = text <> :binary.copy(<<0>>, size)
    binary_part(padded, 0, size)
  end

  defp send_userdata_response(state, request_pdu, request, opts \\ []) do
    request_parameter = request.parameter

    response = %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :response,
        function_group: request_parameter.function_group,
        subfunction: Keyword.get(opts, :subfunction, request_parameter.subfunction),
        sequence: Keyword.get(opts, :sequence, request_parameter.sequence),
        data_unit_reference: 1,
        last_data_unit: 0,
        error_code: Keyword.get(opts, :error_code, 0)
      },
      payload: %Payload{
        return_code: Keyword.get(opts, :return_code, 0xFF),
        transport_size: Keyword.get(opts, :transport_size, 0x09),
        data: Keyword.get(opts, :data, request.payload.data)
      }
    }

    {:ok, response_pdu} = UserData.to_pdu(response, request_pdu.header.pdu_reference)
    :ok = send_pdu(state, response_pdu)
    state
  end

  defp send_programmer_indication(%{programmer_fault: :silence_indication} = state), do: state

  defp send_programmer_indication(%{programmer_pending: pending} = state) do
    sequence =
      if state.programmer_fault == :wrong_programmer_sequence,
        do: pending.sequence + 1,
        else: pending.sequence

    indication = %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :indication,
        function_group: :programmer,
        subfunction: pending.subfunction,
        sequence: sequence,
        data_unit_reference: 0,
        last_data_unit: 0,
        error_code: 0
      },
      payload: %Payload{
        transport_size: 9,
        data: programmer_indication_service_data(state, pending)
      }
    }

    {:ok, indication_pdu} = UserData.to_pdu(indication, 0)
    _result = send_pdu(state, indication_pdu)
    state
  end

  defp programmer_indication_service_data(%{programmer_fault: :malformed_indication}, _pending),
    do: <<0, 4, 0, 2, 1>>

  defp programmer_indication_service_data(state, %{subfunction: 2} = pending) do
    parameters = Keyword.get(state.options, :programmer_event_parameters, <<1, 0, 0, 2>>)
    data = programmer_variable_data(state, pending.setup_data)
    {:ok, encoded} = Programmer.encode_service_data(parameters, data, :variable_status)
    encoded
  end

  defp programmer_indication_service_data(state, pending) do
    parameters =
      Keyword.get(
        state.options,
        :programmer_event_parameters,
        <<1, 0, pending.sequence::unsigned-big-16>>
      )

    data = Keyword.get(state.options, :programmer_event_data, "diagnostic")
    {:ok, encoded} = Programmer.encode_service_data(parameters, data, :programmer_diagnostic)
    encoded
  end

  defp programmer_variable_data(state, <<count::unsigned-big-16, addresses::binary>>) do
    <<address_items::binary-size(count * 6)>> = addresses
    values = Keyword.get(state.options, :programmer_values)

    encoded =
      address_items
      |> programmer_address_sizes([])
      |> Enum.with_index()
      |> Enum.map(fn {size, index} ->
        value = programmer_value(values, size, index)
        padding = if rem(size, 2) == 1, do: <<0>>, else: <<>>
        <<0xFF, 9, size::unsigned-big-16, value::binary, padding::binary>>
      end)

    IO.iodata_to_binary([<<count::unsigned-big-16>>, encoded])
  end

  defp programmer_address_sizes(<<>>, sizes), do: Enum.reverse(sizes)

  defp programmer_address_sizes(
         <<area, repetition, _db::unsigned-big-16, _offset::unsigned-big-16, rest::binary>>,
         sizes
       ) do
    width =
      cond do
        area in [0x54, 0x64] -> 2
        Bitwise.band(area, 0x0F) == 0 -> 1
        Bitwise.band(area, 0x0F) == 3 -> 4
        true -> Bitwise.band(area, 0x0F)
      end

    count = if Bitwise.band(area, 0x0F) == 0, do: 1, else: repetition
    programmer_address_sizes(rest, [width * count | sizes])
  end

  defp programmer_value(values, size, index) when is_list(values) do
    value = Enum.at(values, index, :binary.copy(<<0>>, size))
    true = is_binary(value) and byte_size(value) == size
    value
  end

  defp programmer_value(_values, 6, 0), do: <<0x41, 0x33, 0x85, 0x1F, 0xDE, 0xAD>>
  defp programmer_value(_values, 1, 1), do: <<2>>
  defp programmer_value(_values, size, _index), do: :binary.copy(<<0>>, size)

  defp handle_alarm_subscribe(state, request_pdu, request, decoded) do
    state = notify_request(state, :alarm_subscribe, request_pdu)

    case state.alarm_fault do
      :setup_silence ->
        %{state | alarm_fault: nil}

      :setup_rejected ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          error_code: 0xD241,
          data: <<>>
        )

      :malformed_setup ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request, data: <<0>>)

      _other ->
        subscription = %{
          alarm_type: decoded.alarm_type,
          subscription_key: decoded.subscription_key
        }

        state =
          send_userdata_response(state, request_pdu, request,
            data: <<2, 0, alarm_subscription_state(decoded.alarm_type, :subscribe), 1, 0>>
          )

        state
        |> Map.put(:alarm_subscription, subscription)
        |> send_alarm_pushes(subscription)
    end
  end

  defp handle_alarm_unsubscribe(state, request_pdu, request, decoded) do
    state = notify_request(state, :alarm_unsubscribe, request_pdu)

    case state.alarm_fault do
      :unsubscribe_silence ->
        %{state | alarm_fault: nil}

      :unsubscribe_rejected ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          error_code: 0xD241,
          return_code: 0x0A,
          transport_size: 0,
          data: <<>>
        )

      :malformed_unsubscribe ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request, data: <<0>>)

      _other ->
        state =
          send_userdata_response(state, request_pdu, request,
            data: <<2, 0, alarm_subscription_state(decoded.alarm_type, :unsubscribe), 1, 0>>
          )

        %{state | alarm_subscription: nil}
    end
  end

  defp handle_alarm_query(state, request_pdu, request, decoded) do
    state = notify_request(state, :alarm_query, request_pdu)

    case state.alarm_fault do
      :query_silence ->
        %{state | alarm_fault: nil}

      :query_rejected ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          error_code: 0xD241,
          data: <<>>
        )

      :malformed_query ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          data: <<0, 1, 0xFF, 9, 0, 12, 10, 0>>
        )

      _other ->
        send_userdata_response(state, request_pdu, request,
          data: alarm_query_data(state, decoded.selector)
        )
    end
  end

  defp handle_alarm_acknowledgement(state, request_pdu, request, decoded) do
    state = notify_request(state, :alarm_acknowledge, request_pdu)

    case state.alarm_fault do
      :ack_silence ->
        %{state | alarm_fault: nil}

      :ack_rejected ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          error_code: 0xD241,
          data: <<>>
        )

      :malformed_ack ->
        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          data: <<9, length(decoded.acknowledgements), 0xFF, 0xFF>>
        )

      :ack_item_rejected ->
        count = length(decoded.acknowledgements)
        return_codes = <<0x03, :binary.copy(<<0xFF>>, count - 1)::binary>>

        send_userdata_response(%{state | alarm_fault: nil}, request_pdu, request,
          data: <<9, count, return_codes::binary>>
        )

      _other ->
        count = length(decoded.acknowledgements)

        return_codes =
          Keyword.get(state.options, :alarm_ack_return_codes, :binary.copy(<<0xFF>>, count))

        true = is_binary(return_codes) and byte_size(return_codes) == count

        send_userdata_response(state, request_pdu, request,
          data: <<9, count, return_codes::binary>>
        )
    end
  end

  defp send_alarm_pushes(state, subscription) do
    event_ids =
      case Keyword.fetch(state.options, :alarm_event_ids) do
        {:ok, event_ids} -> event_ids
        :error -> List.duplicate(0xAF, Keyword.get(state.options, :alarm_push_count, 1))
      end

    if event_ids == [] do
      state
    else
      Process.sleep(Keyword.get(state.options, :alarm_push_delay, 20))

      Enum.reduce(event_ids, state, fn event_id, state ->
        send_alarm_indication(state, subscription, event_id)
      end)
    end
  end

  defp send_alarm_indication(
         %{alarm_fault: :silence_indication} = state,
         _subscription,
         _event_id
       ),
       do: %{state | alarm_fault: nil}

  defp send_alarm_indication(state, subscription, event_id) do
    subfunction =
      if state.alarm_fault == :wrong_alarm_subfunction,
        do: 0x07,
        else: alarm_indication_subfunction(subscription.alarm_type)

    data =
      case state.alarm_fault do
        :malformed_indication -> <<0, 1>>
        :invalid_alarm_timestamp -> <<0::unsigned-big-64, 0x40, 0>>
        _other -> alarm_event_data(event_id)
      end

    indication = %UserData{
      parameter: %Parameter{
        method: 0x11,
        type: :indication,
        function_group: :cpu,
        subfunction: subfunction,
        sequence: 0
      },
      payload: %Payload{return_code: 0xFF, transport_size: 0x09, data: data}
    }

    {:ok, indication_pdu} = UserData.to_pdu(indication, 0)
    :ok = send_pdu(state, indication_pdu)

    if state.alarm_fault in [
         :wrong_alarm_subfunction,
         :malformed_indication,
         :invalid_alarm_timestamp
       ],
       do: %{state | alarm_fault: nil},
       else: state
  end

  defp alarm_event_data(event_id) do
    timestamp = <<0x24, 0x08, 0x09, 0x12, 0x34, 0x56, 0x12, 0x36>>
    object = <<0x12, 0x0A, 0x16, 1, event_id::unsigned-big-32, 1, 0, 1, 1>>
    associated_value = <<0xFF, 0x04, 16::unsigned-big-16, 1_234::unsigned-big-16>>
    <<timestamp::binary, 0x40, 1, object::binary, associated_value::binary>>
  end

  defp alarm_query_data(state, selector) do
    if Keyword.get(state.options, :alarm_query_empty, false) do
      <<0, 1, 0x0A, 0, 0::unsigned-big-16>>
    else
      event_ids = alarm_query_event_ids(state.options, selector)

      alarm_type = alarm_query_type(state, selector)
      records = IO.iodata_to_binary(Enum.map(event_ids, &alarm_query_record(alarm_type, &1)))
      count = length(event_ids)
      <<0, count, 0xFF, 0x09, byte_size(records)::unsigned-big-16, records::binary>>
    end
  end

  defp alarm_query_record(alarm_type, event_id) do
    <<10, 0::unsigned-big-16, alarm_type_code(alarm_type), event_id::unsigned-big-32, 0, 1, 1, 1>>
  end

  defp alarm_query_event_ids(options, selector) do
    Keyword.get_lazy(options, :alarm_query_event_ids, fn -> default_alarm_query_ids(selector) end)
  end

  defp default_alarm_query_ids({:event_id, event_id}), do: [event_id]
  defp default_alarm_query_ids({:alarm_type, _alarm_type}), do: [0xAF]

  defp alarm_query_type(_state, {:alarm_type, alarm_type}), do: alarm_type

  defp alarm_query_type(%{alarm_subscription: %{alarm_type: alarm_type}}, {:event_id, _event_id}),
    do: alarm_type

  defp alarm_query_type(_state, {:event_id, _event_id}), do: :alarm_8

  defp alarm_type_code(:alarm_8), do: 0x02
  defp alarm_type_code(:alarm_s), do: 0x04

  defp alarm_subscription_state(:alarm_8, :subscribe), do: 0x05
  defp alarm_subscription_state(:alarm_8, :unsubscribe), do: 0x04
  defp alarm_subscription_state(:alarm_s, :subscribe), do: 0x09
  defp alarm_subscription_state(:alarm_s, :unsubscribe), do: 0x08

  defp alarm_indication_subfunction(:alarm_8), do: 0x05
  defp alarm_indication_subfunction(:alarm_s), do: 0x12

  defp handle_cyclic_subscribe(state, request_pdu, request, decoded) do
    state = notify_request(state, :cyclic_subscribe, request_pdu)
    job_id = Keyword.get(state.options, :cyclic_job_id, state.next_cyclic_job)

    case state.cyclic_fault do
      :setup_silence ->
        %{state | cyclic_fault: nil}

      :setup_rejected ->
        send_userdata_response(%{state | cyclic_fault: nil}, request_pdu, request,
          sequence: job_id,
          error_code: 0xD241,
          data: <<>>
        )

      :malformed_setup ->
        send_userdata_response(%{state | cyclic_fault: nil}, request_pdu, request,
          sequence: job_id,
          data: <<0>>
        )

      _other ->
        job = %{
          id: job_id,
          mode: decoded.mode,
          interval: decoded.interval,
          item_specs: decoded.item_specs,
          subfunction: request.parameter.subfunction
        }

        data =
          if Keyword.get(state.options, :cyclic_empty_initial, false),
            do: <<>>,
            else: cyclic_event_data(state, job, 0)

        state =
          send_userdata_response(state, request_pdu, request,
            sequence: job_id,
            data: data
          )

        state = %{
          state
          | cyclic_jobs: Map.put(state.cyclic_jobs, job_id, job),
            next_cyclic_job: next_job_id(job_id)
        }

        send_cyclic_pushes(state, job)
    end
  end

  defp handle_cyclic_modify(state, request_pdu, request, decoded) do
    state = notify_request(state, :cyclic_modify, request_pdu)

    case {Map.get(state.cyclic_jobs, decoded.job_id), state.cyclic_fault} do
      {_job, :modify_rejected} ->
        send_userdata_response(%{state | cyclic_fault: nil}, request_pdu, request,
          sequence: decoded.job_id,
          error_code: 0xD241,
          data: <<>>
        )

      {nil, _fault} ->
        send_userdata_response(state, request_pdu, request,
          sequence: decoded.job_id,
          error_code: 0xD209,
          data: <<>>
        )

      {job, _fault} ->
        job = %{
          job
          | interval: decoded.interval,
            item_specs: decoded.item_specs,
            subfunction: request.parameter.subfunction
        }

        state =
          send_userdata_response(state, request_pdu, request,
            sequence: decoded.job_id,
            data: cyclic_event_data(state, job, 0)
          )

        state = %{state | cyclic_jobs: Map.put(state.cyclic_jobs, decoded.job_id, job)}
        send_cyclic_pushes(state, job)
    end
  end

  defp handle_cyclic_unsubscribe(state, request_pdu, request, decoded) do
    state = notify_request(state, :cyclic_unsubscribe, request_pdu)

    case state.cyclic_fault do
      :unsubscribe_silence ->
        %{state | cyclic_fault: nil}

      :unsubscribe_rejected ->
        send_userdata_response(%{state | cyclic_fault: nil}, request_pdu, request,
          sequence: decoded.job_id,
          error_code: 0xD241,
          return_code: 0x0A,
          transport_size: 0,
          data: <<>>
        )

      :malformed_unsubscribe ->
        send_userdata_response(%{state | cyclic_fault: nil}, request_pdu, request,
          sequence: decoded.job_id,
          data: <<0>>
        )

      _other ->
        state =
          send_userdata_response(state, request_pdu, request,
            sequence: decoded.job_id,
            return_code: 0x0A,
            transport_size: 0,
            data: <<>>
          )

        %{state | cyclic_jobs: Map.delete(state.cyclic_jobs, decoded.job_id)}
    end
  end

  defp send_cyclic_pushes(state, job) do
    count = Keyword.get(state.options, :cyclic_push_count, 2)

    if count > 0 do
      Process.sleep(Keyword.get(state.options, :cyclic_push_delay, 20))

      Enum.reduce(1..count, state, fn index, state ->
        send_cyclic_indication(state, job, index)
      end)
    else
      state
    end
  end

  defp send_cyclic_indication(%{cyclic_fault: :silence_indication} = state, _job, _index),
    do: %{state | cyclic_fault: nil}

  defp send_cyclic_indication(state, job, index) do
    sequence =
      if state.cyclic_fault == :wrong_cyclic_sequence,
        do: next_job_id(job.id),
        else: job.id

    data =
      if state.cyclic_fault == :malformed_indication,
        do: <<0, 2, 0>>,
        else: cyclic_event_data(state, job, index)

    indication = %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :indication,
        function_group: :cyclic,
        subfunction: job.subfunction,
        sequence: sequence,
        data_unit_reference: 0,
        last_data_unit: 0,
        error_code: 0
      },
      payload: %Payload{return_code: 0xFF, transport_size: 0x09, data: data}
    }

    {:ok, indication_pdu} = UserData.to_pdu(indication, 0)
    :ok = send_pdu(state, indication_pdu)

    if state.cyclic_fault in [:wrong_cyclic_sequence, :malformed_indication],
      do: %{state | cyclic_fault: nil},
      else: state
  end

  defp cyclic_event_data(state, %{mode: :cyclic, item_specs: specs}, event_index) do
    values = Keyword.get(state.options, :cyclic_values, [])

    encoded =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {spec, index} ->
        {:ok, item, <<>>} = Item.decode(spec)
        size = cyclic_item_size(item)
        value = cyclic_value(values, size, index, event_index)
        transport = DataItem.expected_transport(item.transport_size)

        data_item = %DataItem{
          return_code: 0xFF,
          transport_size: transport,
          encoded_length: DataItem.expected_encoded_length(item.transport_size, size),
          data: value
        }

        data_item |> DataItem.encode() |> IO.iodata_to_binary()
      end)

    encode_cyclic_items(encoded)
  end

  defp cyclic_event_data(state, %{mode: :change_driven, item_specs: specs}, event_index) do
    values = Keyword.get(state.options, :cyclic_change_values, [])

    encoded =
      specs
      |> Enum.with_index()
      |> Enum.map(fn {_spec, index} ->
        value = Enum.at(values, index, "change-#{event_index}-#{index}")
        true = is_binary(value) and byte_size(value) <= 0xFFFF
        <<0xFF, 0x09, byte_size(value)::unsigned-big-16, value::binary>>
      end)

    encode_cyclic_items(encoded)
  end

  defp encode_cyclic_items(items) do
    count = length(items)

    encoded =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        if rem(byte_size(item) - 4, 2) == 1 and index < count - 1,
          do: [item, <<0>>],
          else: item
      end)

    IO.iodata_to_binary([<<count::unsigned-big-16>>, encoded])
  end

  defp cyclic_item_size(%Item{transport_size: :bit, count: count}), do: div(count + 7, 8)

  defp cyclic_item_size(%Item{transport_size: transport, count: count})
       when transport in [:byte, :char],
       do: count

  defp cyclic_item_size(%Item{transport_size: transport, count: count})
       when transport in [:word, :int, :date, :s5time, :counter, :timer],
       do: count * 2

  defp cyclic_item_size(%Item{count: count}), do: count * 4

  defp cyclic_value(values, size, index, event_index) do
    case Enum.at(values, index) do
      nil ->
        default_cyclic_value(size, event_index)

      value when is_binary(value) and byte_size(value) == size ->
        value

      value ->
        raise ArgumentError,
              "cyclic value #{inspect(value)} at index #{index} does not contain #{size} bytes"
    end
  end

  defp default_cyclic_value(1, event_index), do: <<rem(event_index, 0x100)>>
  defp default_cyclic_value(2, event_index), do: <<1_234 + event_index::unsigned-big-16>>
  defp default_cyclic_value(size, _event_index), do: :binary.copy(<<0>>, size)

  defp next_job_id(0xFF), do: 1
  defp next_job_id(job_id), do: job_id + 1

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

  defp handle_read(%{read_fault: :remote_disconnect} = state, _request, _item_binary) do
    disconnect = %DisconnectRequest{
      destination_reference: state.client_reference,
      source_reference: state.server_reference,
      reason: 0x80,
      additional_information: "maintenance"
    }

    :ok = send_tpdu(state, disconnect)
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :error_tpdu} = state, _request, _item_binary) do
    error = %ErrorTPDU{
      destination_reference: state.client_reference,
      reject_cause: 2,
      invalid_tpdu: <<2, 0xF0, 0x81>>
    }

    :ok = send_tpdu(state, error)
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :disconnect_confirm} = state, _request, _item_binary) do
    confirm = %DisconnectConfirm{
      destination_reference: state.client_reference,
      source_reference: state.server_reference
    }

    :ok = send_tpdu(state, confirm)
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :oversized_reassembly} = state, _request, _item_binary) do
    negotiated_pdu = Keyword.get(state.options, :negotiated_pdu, 240)
    :ok = send_tpdu(state, %Data{payload: :binary.copy(<<0>>, negotiated_pdu + 1)})
    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :too_many_fragments} = state, _request, _item_binary) do
    for _number <- 0..63 do
      :ok = send_tpdu(state, %Data{payload: <<>>, eot: false, tpdu_number: 0})
    end

    %{state | read_fault: nil}
  end

  defp handle_read(%{read_fault: :many_valid_fragments} = state, request, _item_binary) do
    for _number <- 1..64 do
      :ok = send_tpdu(state, %Data{payload: <<>>, eot: false, tpdu_number: 0})
    end

    response = successful_read_response(request, :word, <<0x04, 0xD2>>)
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

    send_or_defer_read(state, response)
  end

  defp send_or_defer_read(state, response) do
    Process.sleep(Keyword.get(state.options, :read_response_delay, 0))

    case Keyword.get(state.options, :reverse_read_groups) do
      count when is_integer(count) and count > 1 ->
        defer_read(state, response, count)

      _other ->
        :ok = send_pdu(state, response)
        state
    end
  end

  defp defer_read(state, response, count) do
    deferred_reads = [response | state.deferred_reads]

    if Enum.count(deferred_reads) == count do
      Enum.each(deferred_reads, fn deferred -> :ok = send_pdu(state, deferred) end)
      %{state | deferred_reads: []}
    else
      %{state | deferred_reads: deferred_reads}
    end
  end

  defp notify_request(state, operation, request) do
    if Keyword.get(state.options, :notify_requests, false) do
      send(state.owner, {:mock_plc_request, operation, request.header.pdu_reference})
    end

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
      :close_after_write ->
        memory = Map.put(state.memory, memory_key(item), data_item.data)
        :ok = :gen_tcp.close(state.socket)
        %{state | memory: memory}

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
    case receive_cotp_data(state, [], 0) do
      {:ok, payload, state} ->
        {:ok, pdu, <<>>} = PDU.decode(payload)
        {:ok, pdu, state}

      {:cotp, tpdu, state} ->
        {:cotp, tpdu, state}

      {:error, :closed} ->
        {:error, :closed, state}
    end
  end

  defp receive_cotp_data(state, parts, count) when count < 64 do
    case receive_tpkt(state) do
      {:ok, packet, state} ->
        packet.payload
        |> COTP.decode()
        |> handle_received_cotp(state, parts, count)

      {:error, :closed} ->
        {:error, :closed}
    end
  end

  defp handle_received_cotp(
         {:ok, %Data{payload: payload, eot: true, tpdu_number: 0}},
         state,
         parts,
         _count
       ) do
    {:ok, IO.iodata_to_binary([Enum.reverse(parts), payload]), state}
  end

  defp handle_received_cotp(
         {:ok, %Data{payload: payload, eot: false, tpdu_number: 0}},
         state,
         parts,
         count
       ) do
    receive_cotp_data(state, [payload | parts], count + 1)
  end

  defp handle_received_cotp({:ok, tpdu}, state, _parts, _count),
    do: {:cotp, tpdu, state}

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
      send_tpdu(state, %Data{payload: second, tpdu_number: 0})
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
