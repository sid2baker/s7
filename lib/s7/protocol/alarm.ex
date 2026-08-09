defmodule S7.Protocol.Alarm do
  @moduledoc """
  Pure codecs for classic S7comm CPU alarm services.

  The module covers message subscription (`0x02`), alarm query (`0x13`),
  unsolicited alarm indications, and explicit acknowledgment (`0x0B`). Query
  and associated-value records retain raw bytes wherever their application
  type is CPU-specific.
  """

  import Bitwise

  alias S7.{
    AlarmAcknowledgement,
    AlarmEvent,
    AlarmQuery,
    AlarmSubscription,
    AlarmTimestamp,
    Data,
    Error
  }

  alias S7.AlarmAcknowledgement.Result, as: AcknowledgementResult
  alias S7.AlarmEvent.Object, as: AlarmObject
  alias S7.AlarmEvent.Object.AssociatedValue
  alias S7.AlarmQuery.Record, as: QueryRecord
  alias S7.Protocol
  alias S7.Protocol.{PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}

  @message_subscription 0x02
  @alarm_acknowledgement 0x0B
  @alarm_query 0x13

  @request_method 0x11
  @response_method 0x12
  @success 0xFF
  @no_object 0x0A
  @octet_string 0x09
  @null_transport 0x00
  @alarm_class 0x80
  @default_subscription_key "HmiRtm  "

  @alarm_states %{
    {:alarm_8, :subscribe} => 0x05,
    {:alarm_8, :unsubscribe} => 0x04,
    {:alarm_s, :subscribe} => 0x09,
    {:alarm_s, :unsubscribe} => 0x08
  }

  @alarm_codes %{scan: 0x01, alarm_8: 0x02, alarm_s: 0x04}
  @code_to_alarm Map.new(@alarm_codes, fn {type, code} -> {code, type} end)

  @indication_subfunctions %{
    0x05 => :alarm_8,
    0x06 => :notify,
    0x0C => :acknowledgement,
    0x11 => :alarm_sq,
    0x12 => :alarm_s,
    0x13 => :alarm_sc,
    0x16 => :notify_8
  }

  @doc """
  Returns the exact CPU subfunctions routed to an alarm subscription.
  """
  @spec indication_subfunctions() :: [byte()]
  def indication_subfunctions, do: Map.keys(@indication_subfunctions) |> Enum.sort()

  @doc """
  Returns the default eight-byte alarm subscription key.
  """
  @spec default_subscription_key() :: <<_::64>>
  def default_subscription_key, do: @default_subscription_key

  @doc """
  Builds an alarm-only message subscription request.

  `event_mask` is retained for capture verification. Runtime callers use zero,
  causing only the alarm class bit to be set.
  """
  @spec subscription_request(AlarmSubscription.alarm_type(), binary(), byte()) ::
          {:ok, UserData.t()} | {:error, Error.t()}
  def subscription_request(
        alarm_type,
        subscription_key \\ @default_subscription_key,
        event_mask \\ 0
      ) do
    build_subscription_request(
      alarm_type,
      subscription_key,
      event_mask,
      :subscribe,
      :subscribe_alarms
    )
  end

  @doc """
  Builds the family-specific alarm abort request.
  """
  @spec unsubscribe_request(AlarmSubscription.alarm_type(), binary()) ::
          {:ok, UserData.t()} | {:error, Error.t()}
  def unsubscribe_request(alarm_type, subscription_key \\ @default_subscription_key) do
    build_subscription_request(
      alarm_type,
      subscription_key,
      0,
      :unsubscribe,
      :unsubscribe_alarms
    )
  end

  @doc """
  Decodes a subscription or abort response for a correlated request.
  """
  @spec decode_subscription_response(
          PDU.t(),
          UserData.t(),
          0..0xFFFF,
          AlarmSubscription.alarm_type(),
          :subscribe | :unsubscribe,
          atom()
        ) :: :ok | {:error, Error.t()}
  def decode_subscription_response(
        pdu,
        request,
        reference,
        alarm_type,
        action,
        operation
      ) do
    with {:ok, expected_state} <- alarm_state(alarm_type, action, operation),
         {:ok, response} <- UserData.decode_response(pdu, request, reference),
         :ok <- validate_response_parameter(response.parameter, operation),
         :ok <- decode_subscription_data(response.payload, expected_state, operation) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
    end
  end

  @doc """
  Builds a query by alarm family or exact event ID.
  """
  @spec query_request(AlarmQuery.selector()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def query_request(selector) do
    with {:ok, query_type, value} <- encode_query_selector(selector, :query_alarms) do
      data = <<0, 1, 0x12, 0x08, 0x1A, 0, query_type, 0x34, value::unsigned-big-32>>

      UserData.request(:cpu, @alarm_query, data,
        method: @request_method,
        sequence: 0
      )
    end
  end

  @doc """
  Decodes a correlated query response PDU.
  """
  @spec decode_query_response(
          PDU.t(),
          UserData.t(),
          0..0xFFFF,
          AlarmQuery.selector(),
          atom()
        ) :: {:ok, AlarmQuery.t()} | {:error, Error.t()}
  def decode_query_response(pdu, request, reference, selector, operation \\ :query_alarms) do
    case UserData.decode_response(pdu, request, reference) do
      {:ok, response} ->
        translate_query_result(decode_query_response(response, selector, operation), operation)

      {:error, %Error{} = error} ->
        {:error, translate_error(error, operation)}
    end
  end

  @doc """
  Decodes an already-correlated query userdata response.
  """
  @spec decode_query_response(UserData.t(), AlarmQuery.selector(), atom()) ::
          {:ok, AlarmQuery.t()} | {:error, Error.t()}
  def decode_query_response(
        %UserData{parameter: parameter, payload: payload},
        selector,
        operation
      ) do
    with {:ok, _query_type, _value} <- encode_query_selector(selector, operation),
         :ok <- validate_response_parameter(parameter, operation),
         :ok <- validate_octet_payload(payload, operation) do
      decode_query_data(payload.data, selector, operation)
    end
  end

  def decode_query_response(_response, _selector, operation), do: Protocol.malformed(operation)

  @doc """
  Decodes one unsolicited alarm indication.
  """
  @spec decode_indication(UserData.t(), atom()) ::
          {:ok, AlarmEvent.t()} | {:error, Error.t()}
  def decode_indication(message, operation \\ :next_alarm)

  def decode_indication(
        %UserData{parameter: %Parameter{} = parameter, payload: %Payload{} = payload},
        operation
      ) do
    with {:ok, kind} <- validate_indication_parameter(parameter, operation),
         :ok <- validate_octet_payload(payload, operation),
         {:ok, timestamp, function_id, count, rest} <-
           decode_event_header(payload.data, operation),
         {:ok, objects, <<>>} <- decode_objects(rest, count, operation, []) do
      {:ok,
       %AlarmEvent{
         subfunction: parameter.subfunction,
         kind: kind,
         timestamp: timestamp,
         function_id: function_id,
         objects: objects,
         raw: payload.data
       }}
    else
      {:ok, _objects, trailing} ->
        Protocol.malformed(operation, %{trailing_bytes: byte_size(trailing)})

      {:more, needed} ->
        Protocol.malformed(operation, %{bytes_needed: needed})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def decode_indication(_message, operation), do: Protocol.malformed(operation)

  @doc """
  Normalizes acknowledgment structs, event objects, or one complete event.
  """
  @spec acknowledgements(
          AlarmAcknowledgement.t()
          | AlarmObject.t()
          | AlarmEvent.t()
          | [AlarmAcknowledgement.t() | AlarmObject.t()],
          atom()
        ) :: {:ok, [AlarmAcknowledgement.t()]} | {:error, Error.t()}
  def acknowledgements(value, operation \\ :acknowledge_alarms)

  def acknowledgements(%AlarmEvent{objects: objects}, operation),
    do: acknowledgements(objects, operation)

  def acknowledgements(value, operation) when not is_list(value),
    do: acknowledgements([value], operation)

  def acknowledgements(values, operation) when is_list(values) and values != [] do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {value, index}, {:ok, acknowledgements} ->
      case normalize_acknowledgement(value, operation) do
        {:ok, acknowledgement} ->
          {:cont, {:ok, [acknowledgement | acknowledgements]}}

        {:error, %Error{} = error} ->
          error = %{error | details: Map.put(error.details, :index, index)}
          {:halt, {:error, error}}
      end
    end)
    |> reverse_acknowledgements()
  end

  def acknowledgements(_values, operation),
    do: Protocol.error(operation, :invalid_alarm_acknowledgement)

  @doc """
  Builds one explicit alarm acknowledgment request.
  """
  @spec acknowledgement_request([AlarmAcknowledgement.t()]) ::
          {:ok, UserData.t()} | {:error, Error.t()}
  def acknowledgement_request(acknowledgements) do
    with {:ok, acknowledgements} <- acknowledgements(acknowledgements),
         {:ok, data} <- encode_acknowledgements(acknowledgements) do
      UserData.request(:cpu, @alarm_acknowledgement, data,
        method: @request_method,
        sequence: 0
      )
    end
  end

  @doc """
  Decodes one correlated alarm acknowledgment response.
  """
  @spec decode_acknowledgement_response(
          PDU.t(),
          UserData.t(),
          0..0xFFFF,
          [AlarmAcknowledgement.t()],
          atom()
        ) :: {:ok, [AcknowledgementResult.t()]} | {:error, Error.t()}
  def decode_acknowledgement_response(
        pdu,
        request,
        reference,
        acknowledgements,
        operation \\ :acknowledge_alarms
      ) do
    with {:ok, response} <- UserData.decode_response(pdu, request, reference),
         :ok <- validate_response_parameter(response.parameter, operation),
         :ok <- validate_octet_payload(response.payload, operation),
         {:ok, results} <-
           decode_acknowledgement_data(response.payload.data, acknowledgements, operation) do
      {:ok, results}
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
    end
  end

  @doc false
  @spec decode_request(UserData.t(), atom()) :: {:ok, map()} | {:error, Error.t()}
  def decode_request(
        %UserData{
          parameter: %Parameter{
            method: @request_method,
            type: :request,
            function_group: :cpu,
            subfunction: @message_subscription,
            sequence: 0
          },
          payload: %Payload{
            return_code: @success,
            transport_size: @octet_string,
            data: <<mask, 0, key::binary-size(8), state, reserve>>
          }
        },
        operation
      ) do
    with true <- (mask &&& @alarm_class) == @alarm_class,
         {:ok, alarm_type, action} <- decode_alarm_state(state, operation) do
      {:ok,
       %{
         action: action,
         alarm_type: alarm_type,
         subscription_key: key,
         event_mask: mask &&& 0x7F,
         reserve: reserve
       }}
    else
      false -> Protocol.error(operation, :invalid_alarm_subscription)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def decode_request(
        %UserData{
          parameter: %Parameter{
            method: @request_method,
            type: :request,
            function_group: :cpu,
            subfunction: @alarm_query,
            sequence: 0
          },
          payload: %Payload{
            return_code: @success,
            transport_size: @octet_string,
            data: <<0, 1, 0x12, 0x08, 0x1A, 0, query_type, 0x34, value::unsigned-big-32>>
          }
        },
        operation
      ) do
    decode_query_request(query_type, value, operation)
  end

  def decode_request(
        %UserData{
          parameter: %Parameter{
            method: @request_method,
            type: :request,
            function_group: :cpu,
            subfunction: @alarm_acknowledgement,
            sequence: 0
          },
          payload: %Payload{
            return_code: @success,
            transport_size: @octet_string,
            data: data
          }
        },
        operation
      ) do
    decode_acknowledgement_request_data(data, operation)
  end

  def decode_request(_request, operation),
    do: Protocol.error(operation, :invalid_alarm_request)

  defp build_subscription_request(
         alarm_type,
         subscription_key,
         event_mask,
         action,
         operation
       ) do
    with {:ok, state} <- alarm_state(alarm_type, action, operation),
         :ok <- validate_subscription_key(subscription_key, operation),
         true <- event_mask in 0..0x7F do
      mask = @alarm_class ||| event_mask

      UserData.request(
        :cpu,
        @message_subscription,
        <<mask, 0, subscription_key::binary-size(8), state, 0>>,
        method: @request_method,
        sequence: 0
      )
    else
      false -> Protocol.error(operation, :invalid_alarm_event_mask)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp alarm_state(alarm_type, action, operation) do
    case Map.fetch(@alarm_states, {alarm_type, action}) do
      {:ok, state} -> {:ok, state}
      :error -> Protocol.error(operation, :unsupported_alarm_type, details: %{type: alarm_type})
    end
  end

  defp decode_alarm_state(state, operation) do
    case Enum.find(@alarm_states, fn {_key, code} -> code == state end) do
      {{alarm_type, action}, _state} -> {:ok, alarm_type, action}
      nil -> Protocol.error(operation, :unsupported_alarm_state, code: state)
    end
  end

  defp validate_subscription_key(key, _operation)
       when is_binary(key) and byte_size(key) == 8,
       do: :ok

  defp validate_subscription_key(key, operation),
    do: Protocol.error(operation, :invalid_alarm_subscription_key, details: %{key: key})

  defp decode_subscription_data(
         %Payload{return_code: @success, transport_size: @octet_string, data: <<>>},
         _expected_state,
         _operation
       ),
       do: :ok

  defp decode_subscription_data(
         %Payload{
           return_code: @success,
           transport_size: @octet_string,
           data: <<result, _reserved>>
         },
         _expected_state,
         operation
       ),
       do: subscription_result(result, operation)

  defp decode_subscription_data(
         %Payload{
           return_code: @success,
           transport_size: @octet_string,
           data: <<result, _reserved, state, _tail::binary-size(2)>>
         },
         expected_state,
         operation
       ) do
    with true <- state == expected_state,
         :ok <- subscription_result(result, operation) do
      :ok
    else
      false ->
        Protocol.malformed(operation, %{expected_alarm_state: expected_state, received: state})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp decode_subscription_data(_payload, _expected_state, operation),
    do: Protocol.malformed(operation)

  defp subscription_result(result, _operation) when result in [0x00, 0x02], do: :ok

  defp subscription_result(result, operation),
    do: Protocol.error(operation, :alarm_subscription_rejected, code: result)

  defp encode_query_selector({:alarm_type, alarm_type}, operation) do
    case @alarm_codes do
      %{^alarm_type => code} when alarm_type in [:alarm_s, :alarm_8] -> {:ok, 0x01, code}
      _other -> Protocol.error(operation, :unsupported_alarm_type, details: %{type: alarm_type})
    end
  end

  defp encode_query_selector({:event_id, event_id}, _operation)
       when event_id in 0..0xFFFFFFFF,
       do: {:ok, 0x03, event_id}

  defp encode_query_selector(selector, operation),
    do: Protocol.error(operation, :invalid_alarm_query, details: %{selector: selector})

  defp decode_query_request(0x01, code, operation) do
    case @code_to_alarm do
      %{^code => alarm_type} when alarm_type in [:alarm_s, :alarm_8] ->
        {:ok, %{action: :query, selector: {:alarm_type, alarm_type}}}

      _other ->
        Protocol.error(operation, :unsupported_alarm_type, code: code)
    end
  end

  defp decode_query_request(0x03, event_id, _operation),
    do: {:ok, %{action: :query, selector: {:event_id, event_id}}}

  defp decode_query_request(query_type, _value, operation),
    do: Protocol.error(operation, :unsupported_alarm_query, code: query_type)

  defp decode_query_data(
         <<function_id, reported_count, return_code, transport_size,
           complete_length::unsigned-big-16, records::binary>> = raw,
         selector,
         operation
       ) do
    with :ok <-
           validate_query_result(return_code, transport_size, complete_length, records, operation),
         {:ok, decoded_records} <-
           decode_query_records(records, complete_length, operation) do
      {:ok,
       %AlarmQuery{
         selector: selector,
         function_id: function_id,
         reported_count: reported_count,
         return_code: return_code,
         transport_size: transport_size,
         complete_length: complete_length,
         records: decoded_records,
         raw: raw
       }}
    end
  end

  defp decode_query_data(_data, _selector, operation), do: Protocol.malformed(operation)

  defp validate_query_result(@success, @octet_string, 0xFFFF, records, operation) do
    if byte_size(records) > 0,
      do: :ok,
      else: Protocol.malformed(operation, %{complete_length: 0xFFFF})
  end

  defp validate_query_result(@success, @octet_string, length, records, operation) do
    if byte_size(records) == length,
      do: :ok,
      else:
        Protocol.malformed(operation, %{
          complete_length: length,
          received_length: byte_size(records)
        })
  end

  defp validate_query_result(@no_object, @null_transport, 0, <<>>, _operation), do: :ok

  defp validate_query_result(return_code, _transport, _length, _records, operation),
    do: Protocol.item_result(operation, return_code)

  defp decode_query_records(_records, 0, _operation), do: {:ok, []}

  defp decode_query_records(records, 0xFFFF, operation) do
    case decode_query_record_list(records, operation, []) do
      {:ok, parsed, <<0>>} ->
        {:ok, parsed}

      {:ok, _parsed, trailing} ->
        Protocol.malformed(operation, %{trailing_bytes: byte_size(trailing)})

      other ->
        other
    end
  end

  defp decode_query_records(records, _complete_length, operation) do
    case decode_query_record_list(records, operation, []) do
      {:ok, parsed, <<>>} ->
        {:ok, parsed}

      {:ok, _parsed, trailing} ->
        Protocol.malformed(operation, %{trailing_bytes: byte_size(trailing)})

      other ->
        other
    end
  end

  defp decode_query_record_list(<<>>, _operation, records),
    do: {:ok, Enum.reverse(records), <<>>}

  defp decode_query_record_list(<<0, _rest::binary>> = terminator, _operation, records),
    do: {:ok, Enum.reverse(records), terminator}

  defp decode_query_record_list(<<dataset_length, _rest::binary>> = binary, operation, records) do
    total = dataset_length + 2

    cond do
      total < 12 ->
        Protocol.malformed(operation, %{dataset_length: dataset_length})

      byte_size(binary) < total ->
        Protocol.malformed(operation, %{bytes_needed: total - byte_size(binary)})

      true ->
        <<record_raw::binary-size(total), remaining::binary>> = binary

        record = decode_query_record(record_raw)
        decode_query_record_list(remaining, operation, [record | records])
    end
  end

  defp decode_query_record_list(_binary, operation, _records), do: Protocol.malformed(operation)

  defp decode_query_record(
         <<dataset_length, reserved::unsigned-big-16, alarm_code, event_id::unsigned-big-32,
           reserved_state, event_state, ack_state_going, ack_state_coming, details::binary>> = raw
       ) do
    %QueryRecord{
      dataset_length: dataset_length,
      reserved: reserved,
      alarm_type: Map.get(@code_to_alarm, alarm_code, alarm_code),
      event_id: event_id,
      reserved_state: reserved_state,
      event_state: event_state,
      ack_state_going: ack_state_going,
      ack_state_coming: ack_state_coming,
      details: details,
      raw: raw
    }
  end

  defp decode_event_header(
         <<timestamp_raw::binary-size(8), function_id, count, rest::binary>>,
         operation
       ) do
    case Data.decode(:date_and_time, timestamp_raw) do
      {:ok, datetime} ->
        # The final byte is milliseconds-low in the high nibble and weekday in the low nibble.
        <<_prefix::binary-size(7), final>> = timestamp_raw

        {:ok, %AlarmTimestamp{datetime: datetime, weekday: final &&& 0x0F, raw: timestamp_raw},
         function_id, count, rest}

      {:error, %Error{}} ->
        Protocol.malformed(operation, %{timestamp: timestamp_raw})
    end
  end

  defp decode_event_header(binary, _operation) when is_binary(binary) and byte_size(binary) < 10,
    do: {:more, 10 - byte_size(binary)}

  defp decode_event_header(_data, operation), do: Protocol.malformed(operation)

  defp decode_objects(remaining, 0, _operation, objects),
    do: {:ok, Enum.reverse(objects), remaining}

  defp decode_objects(binary, count, operation, objects) when count > 0 do
    with {:ok, object, remaining} <- decode_object(binary, operation) do
      decode_objects(remaining, count - 1, operation, [object | objects])
    end
  end

  defp decode_object(binary, _operation) when is_binary(binary) and byte_size(binary) < 2,
    do: {:more, 2 - byte_size(binary)}

  defp decode_object(<<0x12, length, rest::binary>> = binary, operation) do
    if byte_size(rest) < length do
      {:more, length - byte_size(rest)}
    else
      <<body::binary-size(length), associated_data::binary>> = rest
      specification_raw = <<0x12, length, body::binary>>

      with {:ok, fields} <- decode_object_body(body, operation),
           {:ok, values, remaining} <-
             decode_associated_values(
               associated_data,
               fields.associated_value_count,
               operation,
               []
             ) do
        consumed = byte_size(binary) - byte_size(remaining)
        raw = binary_part(binary, 0, consumed)

        {:ok,
         struct!(
           AlarmObject,
           fields
           |> Map.put(:length, length)
           |> Map.put(:associated_values, values)
           |> Map.put(:specification_raw, specification_raw)
           |> Map.put(:raw, raw)
           |> Map.put(:fixed_extra, fields.fixed_extra)
         ), remaining}
      end
    end
  end

  defp decode_object(_binary, operation), do: Protocol.malformed(operation)

  defp decode_object_body(
         <<0x16, value_count, event_id::unsigned-big-32, event_state, local_state,
           ack_state_going, ack_state_coming, extra::binary>>,
         _operation
       ) do
    {:ok,
     %{
       syntax_id: 0x16,
       associated_value_count: value_count,
       event_id: event_id,
       event_state: event_state,
       local_state: local_state,
       ack_state_going: ack_state_going,
       ack_state_coming: ack_state_coming,
       event_state_going: nil,
       event_state_coming: nil,
       event_state_last_changed: nil,
       reserved_state: nil,
       fixed_extra: empty_to_nil(extra)
     }}
  end

  defp decode_object_body(
         <<0x19, value_count, event_id::unsigned-big-32, ack_state_going, ack_state_coming,
           extra::binary>>,
         _operation
       ) do
    {:ok,
     %{
       syntax_id: 0x19,
       associated_value_count: value_count,
       event_id: event_id,
       event_state: nil,
       local_state: nil,
       ack_state_going: ack_state_going,
       ack_state_coming: ack_state_coming,
       event_state_going: nil,
       event_state_coming: nil,
       event_state_last_changed: nil,
       reserved_state: nil,
       fixed_extra: empty_to_nil(extra)
     }}
  end

  defp decode_object_body(
         <<0x1C, value_count, event_id::unsigned-big-32, event_state, local_state,
           ack_state_going, ack_state_coming, event_state_going, event_state_coming,
           event_state_last_changed, reserved_state, extra::binary>>,
         _operation
       ) do
    {:ok,
     %{
       syntax_id: 0x1C,
       associated_value_count: value_count,
       event_id: event_id,
       event_state: event_state,
       local_state: local_state,
       ack_state_going: ack_state_going,
       ack_state_coming: ack_state_coming,
       event_state_going: event_state_going,
       event_state_coming: event_state_coming,
       event_state_last_changed: event_state_last_changed,
       reserved_state: reserved_state,
       fixed_extra: empty_to_nil(extra)
     }}
  end

  defp decode_object_body(
         <<syntax_id, value_count, event_id::unsigned-big-32, extra::binary>>,
         _operation
       ) do
    {:ok,
     %{
       syntax_id: syntax_id,
       associated_value_count: value_count,
       event_id: event_id,
       event_state: nil,
       local_state: nil,
       ack_state_going: nil,
       ack_state_coming: nil,
       event_state_going: nil,
       event_state_coming: nil,
       event_state_last_changed: nil,
       reserved_state: nil,
       fixed_extra: empty_to_nil(extra)
     }}
  end

  defp decode_object_body(_body, operation), do: Protocol.malformed(operation)

  defp decode_associated_values(remaining, 0, _operation, values),
    do: {:ok, Enum.reverse(values), remaining}

  defp decode_associated_values(binary, count, operation, values) when count > 0 do
    with {:ok, value, remaining} <- decode_associated_value(binary, operation) do
      decode_associated_values(remaining, count - 1, operation, [value | values])
    end
  end

  defp decode_associated_value(binary, _operation)
       when is_binary(binary) and byte_size(binary) < 4,
       do: {:more, 4 - byte_size(binary)}

  defp decode_associated_value(
         <<return_code, transport_size, encoded_length::unsigned-big-16, rest::binary>> = binary,
         operation
       ) do
    payload_size = associated_payload_size(transport_size, encoded_length)

    if byte_size(rest) < payload_size do
      {:more, payload_size - byte_size(rest)}
    else
      <<data::binary-size(payload_size), remaining::binary>> = rest
      consumed = byte_size(binary) - byte_size(remaining)
      raw = binary_part(binary, 0, consumed)

      error =
        case Protocol.item_result(operation, return_code) do
          :ok -> nil
          {:error, %Error{} = error} -> error
        end

      {:ok,
       %AssociatedValue{
         return_code: return_code,
         transport_size: transport_size,
         encoded_length: encoded_length,
         data: data,
         error: error,
         raw: raw
       }, remaining}
    end
  end

  defp associated_payload_size(transport_size, encoded_length)
       when transport_size in [0x03, 0x04, 0x05],
       do: div(encoded_length + 7, 8)

  defp associated_payload_size(_transport_size, encoded_length), do: encoded_length

  defp validate_indication_parameter(%Parameter{} = parameter, operation) do
    case Map.fetch(@indication_subfunctions, parameter.subfunction) do
      {:ok, kind} ->
        cond do
          parameter.method != @request_method or parameter.type != :indication ->
            Protocol.malformed(operation, %{
              method: parameter.method,
              userdata_type: parameter.type
            })

          parameter.function_group != :cpu or parameter.sequence != 0 ->
            Protocol.malformed(operation, %{
              function_group: parameter.function_group,
              sequence: parameter.sequence
            })

          not Parameter.final_unit?(parameter) ->
            Protocol.malformed(operation)

          true ->
            {:ok, kind}
        end

      :error ->
        Protocol.error(operation, :unsupported_alarm_indication, code: parameter.subfunction)
    end
  end

  defp validate_response_parameter(
         %Parameter{method: @response_method, type: :response} = parameter,
         operation
       ) do
    if Parameter.final_unit?(parameter), do: :ok, else: Protocol.malformed(operation)
  end

  defp validate_response_parameter(_parameter, operation), do: Protocol.malformed(operation)

  defp validate_octet_payload(
         %Payload{return_code: @success, transport_size: @octet_string},
         _operation
       ),
       do: :ok

  defp validate_octet_payload(%Payload{return_code: return_code}, operation),
    do: Protocol.item_result(operation, return_code)

  defp normalize_acknowledgement(%AlarmAcknowledgement{} = acknowledgement, operation) do
    if acknowledgement.event_id in 0..0xFFFFFFFF and
         acknowledgement.ack_state_going in 0..0xFF and
         acknowledgement.ack_state_coming in 0..0xFF do
      {:ok, acknowledgement}
    else
      Protocol.error(operation, :invalid_alarm_acknowledgement)
    end
  end

  defp normalize_acknowledgement(%AlarmObject{} = object, operation) do
    normalize_acknowledgement(
      %AlarmAcknowledgement{
        event_id: object.event_id,
        ack_state_going: object.ack_state_going,
        ack_state_coming: object.ack_state_coming
      },
      operation
    )
  end

  defp normalize_acknowledgement(_value, operation),
    do: Protocol.error(operation, :invalid_alarm_acknowledgement)

  defp reverse_acknowledgements({:ok, acknowledgements}),
    do: {:ok, Enum.reverse(acknowledgements)}

  defp reverse_acknowledgements({:error, %Error{} = error}), do: {:error, error}

  defp encode_acknowledgements(acknowledgements) do
    count = Enum.count_until(acknowledgements, 0x100)

    if count in 1..0xFF do
      objects =
        Enum.map(acknowledgements, fn acknowledgement ->
          <<0x12, 0x08, 0x19, 0, acknowledgement.event_id::unsigned-big-32,
            acknowledgement.ack_state_going, acknowledgement.ack_state_coming>>
        end)

      {:ok, IO.iodata_to_binary([<<0x09, count>>, objects])}
    else
      Protocol.error(:acknowledge_alarms, :invalid_alarm_acknowledgement_count)
    end
  end

  defp decode_acknowledgement_request_data(<<0x09, count, objects::binary>>, operation)
       when count > 0 do
    expected_size = count * 10

    if byte_size(objects) == expected_size do
      decode_acknowledgement_objects(objects, count, operation, [])
    else
      Protocol.malformed(operation, %{
        expected_size: expected_size,
        received_size: byte_size(objects)
      })
    end
  end

  defp decode_acknowledgement_request_data(_data, operation),
    do: Protocol.error(operation, :invalid_alarm_acknowledgement)

  defp decode_acknowledgement_objects(<<>>, 0, _operation, acknowledgements),
    do: {:ok, %{action: :acknowledge, acknowledgements: Enum.reverse(acknowledgements)}}

  defp decode_acknowledgement_objects(
         <<0x12, 0x08, 0x19, 0, event_id::unsigned-big-32, ack_state_going, ack_state_coming,
           rest::binary>>,
         count,
         operation,
         acknowledgements
       )
       when count > 0 do
    acknowledgement = %AlarmAcknowledgement{
      event_id: event_id,
      ack_state_going: ack_state_going,
      ack_state_coming: ack_state_coming
    }

    decode_acknowledgement_objects(rest, count - 1, operation, [
      acknowledgement | acknowledgements
    ])
  end

  defp decode_acknowledgement_objects(_objects, _count, operation, _acknowledgements),
    do: Protocol.malformed(operation)

  defp decode_acknowledgement_data(
         <<0x09, count, return_codes::binary>>,
         acknowledgements,
         operation
       )
       when count == byte_size(return_codes) and count == length(acknowledgements) do
    results =
      acknowledgements
      |> Enum.zip(:binary.bin_to_list(return_codes))
      |> Enum.map(fn {acknowledgement, return_code} ->
        case Protocol.item_result(operation, return_code) do
          :ok ->
            %AcknowledgementResult{
              acknowledgement: acknowledgement,
              return_code: return_code,
              status: :ok,
              error: nil
            }

          {:error, %Error{} = error} ->
            %AcknowledgementResult{
              acknowledgement: acknowledgement,
              return_code: return_code,
              status: :error,
              error: error
            }
        end
      end)

    {:ok, results}
  end

  defp decode_acknowledgement_data(_data, _acknowledgements, operation),
    do: Protocol.malformed(operation)

  defp empty_to_nil(<<>>), do: nil
  defp empty_to_nil(binary), do: binary

  defp translate_error(%Error{reason: :userdata_error, code: 0xD241} = error, operation),
    do: %{error | operation: operation, reason: :access_denied}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD209} = error, operation),
    do: %{error | operation: operation, reason: :object_not_found}

  defp translate_error(error, operation), do: %{error | operation: operation}

  defp translate_query_result({:ok, %AlarmQuery{} = query}, _operation), do: {:ok, query}

  defp translate_query_result({:error, %Error{} = error}, operation),
    do: {:error, translate_error(error, operation)}
end
