defmodule S7.Protocol.Cyclic do
  @moduledoc """
  Codec for bounded classic S7comm cyclic-service jobs.

  Fixed cyclic transfer (`0x01`) uses typed S7ANY items. Change-driven setup
  (`0x05`) and modification (`0x07`) accept complete raw variable
  specifications so capture-backed DBREAD and CPU-specific variants are not
  collapsed into an inaccurate high-level model.
  """

  alias S7.{Address, Data, Error}
  alias S7.Cyclic, as: CyclicModel
  alias S7.Cyclic.Event.Item, as: EventItem
  alias S7.Protocol
  alias S7.Protocol.{DataItem, Item, PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}

  @cyclic_transfer 0x01
  @unsubscribe 0x04
  @change_driven 0x05
  @change_modify 0x07
  @unsubscribe_job 0x05
  @method_request 0x11
  @method_response 0x12
  @success 0xFF
  @null_success 0x0A
  @octet_string 0x09
  @null 0x00

  @base_codes %{hundred_milliseconds: 0, second: 1, ten_seconds: 2}

  @doc """
  Converts an exact millisecond interval into the coarsest wire base that can
  represent it without rounding.
  """
  @spec interval(pos_integer() | CyclicModel.Interval.t(), atom()) ::
          {:ok, CyclicModel.Interval.t()} | {:error, Error.t()}
  def interval(value, operation \\ :subscribe_cyclic)

  def interval(%CyclicModel.Interval{} = interval, operation) do
    with {:ok, _code} <- Map.fetch(@base_codes, interval.base),
         true <- interval.factor in 1..0xFF,
         true <- interval.milliseconds == base_milliseconds(interval.base) * interval.factor do
      {:ok, interval}
    else
      _other -> invalid_interval(operation, interval)
    end
  end

  def interval(milliseconds, operation) when is_integer(milliseconds) do
    cond do
      milliseconds in 10_000..2_550_000 and rem(milliseconds, 10_000) == 0 ->
        build_interval(:ten_seconds, div(milliseconds, 10_000))

      milliseconds in 1_000..255_000 and rem(milliseconds, 1_000) == 0 ->
        build_interval(:second, div(milliseconds, 1_000))

      milliseconds in 100..25_500 and rem(milliseconds, 100) == 0 ->
        build_interval(:hundred_milliseconds, div(milliseconds, 100))

      true ->
        invalid_interval(operation, milliseconds)
    end
  end

  def interval(value, operation), do: invalid_interval(operation, value)

  @doc """
  Encodes normalized addresses as S7ANY specifications for fixed cyclic
  transfer.
  """
  @spec typed_item_specs([Address.t()], atom()) :: {:ok, [binary()]} | {:error, Error.t()}
  def typed_item_specs(addresses, operation \\ :subscribe_cyclic)

  def typed_item_specs(addresses, operation) when is_list(addresses) and addresses != [] do
    addresses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {address, index}, {:ok, specs} ->
      case typed_item_spec(address, index, operation) do
        {:ok, item_spec} -> {:cont, {:ok, [item_spec | specs]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> reverse_specs()
  end

  def typed_item_specs(items, operation), do: invalid_items(operation, items)

  defp typed_item_spec(%Address{} = address, index, operation) do
    case Item.from_address(address) do
      {:ok, item} -> {:ok, Item.encode(item)}
      {:error, %Error{} = error} -> {:error, add_index(error, index, operation)}
    end
  end

  defp typed_item_spec(_address, index, operation),
    do: invalid_item(operation, index, :invalid_address)

  @doc """
  Validates complete raw cyclic variable specifications.

  S7ANY (`0x10`) and DBREAD (`0xB0`) syntax IDs are accepted. The bytes are
  preserved exactly.
  """
  @spec raw_item_specs([binary()], atom()) :: {:ok, [binary()]} | {:error, Error.t()}
  def raw_item_specs(items, operation \\ :subscribe_cyclic_raw)

  def raw_item_specs(items, operation) when is_list(items) and items != [] do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, specs} ->
      case validate_raw_item(item) do
        :ok -> {:cont, {:ok, [item | specs]}}
        {:error, reason} -> {:halt, invalid_item(operation, index, reason)}
      end
    end)
    |> reverse_specs()
  end

  def raw_item_specs(items, operation), do: invalid_items(operation, items)

  @doc """
  Builds one cyclic or change-driven setup request.
  """
  @spec subscribe_request(
          CyclicModel.Subscription.mode(),
          [binary()],
          CyclicModel.Interval.t(),
          atom()
        ) :: {:ok, UserData.t()} | {:error, Error.t()}
  def subscribe_request(mode, item_specs, interval, operation \\ :subscribe_cyclic)

  def subscribe_request(mode, item_specs, %CyclicModel.Interval{} = interval, operation) do
    with {:ok, subfunction} <- setup_subfunction(mode, operation),
         {:ok, item_specs} <- raw_item_specs(item_specs, operation),
         {:ok, interval} <- interval(interval, operation),
         {:ok, data} <- request_data(item_specs, interval, operation) do
      UserData.request(:cyclic, subfunction, data,
        method: @method_request,
        sequence: 0
      )
    end
  end

  def subscribe_request(_mode, _item_specs, _interval, operation),
    do: invalid_request(operation)

  @doc """
  Builds a change-driven job modification using the existing remote job ID.
  """
  @spec modify_request(byte(), [binary()], CyclicModel.Interval.t(), atom()) ::
          {:ok, UserData.t()} | {:error, Error.t()}
  def modify_request(job_id, item_specs, interval, operation \\ :modify_cyclic)

  def modify_request(
        job_id,
        item_specs,
        %CyclicModel.Interval{} = interval,
        operation
      )
      when job_id in 1..0xFF do
    with {:ok, item_specs} <- raw_item_specs(item_specs, operation),
         {:ok, interval} <- interval(interval, operation),
         {:ok, data} <- request_data(item_specs, interval, operation) do
      UserData.request(:cyclic, @change_modify, data,
        method: @method_request,
        sequence: job_id
      )
    end
  end

  def modify_request(_job_id, _item_specs, _interval, operation),
    do: invalid_request(operation)

  @doc """
  Builds a request to release one remote cyclic job.
  """
  @spec unsubscribe_request(byte(), atom()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def unsubscribe_request(job_id, operation \\ :unsubscribe_cyclic)

  def unsubscribe_request(job_id, _operation) when job_id in 1..0xFF do
    UserData.request(:cyclic, @unsubscribe, <<@unsubscribe_job, job_id>>,
      method: @method_request,
      sequence: 0
    )
  end

  def unsubscribe_request(_job_id, operation), do: invalid_request(operation)

  @doc """
  Decodes a setup response, including an optional initial snapshot.
  """
  @spec decode_subscribe_response(
          PDU.t(),
          UserData.t(),
          0..0xFFFF,
          CyclicModel.Subscription.mode(),
          [Address.t()] | nil,
          non_neg_integer(),
          atom()
        ) :: {:ok, byte(), CyclicModel.Event.t() | nil} | {:error, Error.t()}
  def decode_subscribe_response(
        pdu,
        request,
        reference,
        mode,
        addresses,
        item_count,
        operation \\ :subscribe_cyclic
      ) do
    with {:ok, response} <- UserData.decode_response(pdu, request, reference),
         :ok <- validate_response_method(response, operation),
         :ok <- validate_snapshot_payload(response.payload, operation),
         job_id when job_id in 1..0xFF <- response.parameter.sequence,
         {:ok, event} <-
           decode_optional_snapshot(response, mode, addresses, item_count, operation) do
      {:ok, job_id, event}
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
      _other -> Protocol.malformed(operation, %{job_id: :invalid})
    end
  end

  @doc """
  Decodes a change-driven modification response.
  """
  @spec decode_modify_response(
          PDU.t(),
          UserData.t(),
          0..0xFFFF,
          byte(),
          non_neg_integer(),
          atom()
        ) :: {:ok, CyclicModel.Event.t() | nil} | {:error, Error.t()}
  def decode_modify_response(
        pdu,
        request,
        reference,
        job_id,
        item_count,
        operation \\ :modify_cyclic
      ) do
    with {:ok, response} <- UserData.decode_response(pdu, request, reference),
         :ok <- validate_response_method(response, operation),
         :ok <- validate_snapshot_payload(response.payload, operation),
         true <- response.parameter.sequence == job_id,
         {:ok, event} <-
           decode_optional_snapshot(response, :change_driven, nil, item_count, operation) do
      {:ok, event}
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
      false -> Protocol.malformed(operation, %{expected_job_id: job_id})
    end
  end

  @doc """
  Decodes an unsubscribe response. Both observed null-success and modeled
  octet-string-empty response shapes are accepted.
  """
  @spec decode_unsubscribe_response(PDU.t(), UserData.t(), 0..0xFFFF, byte(), atom()) ::
          :ok | {:error, Error.t()}
  def decode_unsubscribe_response(
        pdu,
        request,
        reference,
        job_id,
        operation \\ :unsubscribe_cyclic
      ) do
    with {:ok, response} <-
           UserData.decode_response(pdu, request, reference, allow_null_success: true),
         :ok <- validate_response_method(response, operation),
         true <- response.parameter.sequence in [0, job_id],
         :ok <- validate_unsubscribe_payload(response.payload, operation) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
      false -> Protocol.malformed(operation, %{expected_job_id: job_id})
    end
  end

  @doc """
  Decodes one unsolicited update for a known subscription.
  """
  @spec decode_indication(UserData.t(), CyclicModel.Subscription.t(), atom()) ::
          {:ok, CyclicModel.Event.t()} | {:error, Error.t()}
  def decode_indication(message, subscription, operation \\ :next_cyclic)

  def decode_indication(
        %UserData{parameter: %Parameter{} = parameter, payload: %Payload{} = payload},
        %CyclicModel.Subscription{} = subscription,
        operation
      ) do
    with :ok <- validate_indication(parameter, subscription, operation),
         :ok <- validate_event_payload(payload, operation) do
      decode_event(
        payload.data,
        subscription.mode,
        subscription.addresses,
        expected_indication_count(subscription),
        subscription.job_id,
        parameter.subfunction,
        operation
      )
    end
  end

  def decode_indication(_message, _subscription, operation), do: Protocol.malformed(operation)

  @doc false
  @spec mode_subfunctions(CyclicModel.Subscription.mode()) :: [byte()]
  def mode_subfunctions(:cyclic), do: [@cyclic_transfer]
  def mode_subfunctions(:change_driven), do: [@change_driven, @change_modify]
  def mode_subfunctions(_mode), do: []

  @doc false
  @spec decode_request(UserData.t(), atom()) :: {:ok, map()} | {:error, Error.t()}
  def decode_request(
        %UserData{
          parameter: %Parameter{
            method: @method_request,
            type: :request,
            function_group: :cyclic,
            subfunction: @unsubscribe,
            sequence: 0
          },
          payload: %Payload{
            return_code: @success,
            transport_size: @octet_string,
            data: <<@unsubscribe_job, job_id>>
          }
        },
        _operation
      )
      when job_id in 1..0xFF,
      do: {:ok, %{action: :unsubscribe, job_id: job_id}}

  def decode_request(
        %UserData{
          parameter: %Parameter{
            method: @method_request,
            type: :request,
            function_group: :cyclic,
            subfunction: subfunction,
            sequence: sequence
          },
          payload: %Payload{
            return_code: @success,
            transport_size: @octet_string,
            data: data
          }
        },
        operation
      )
      when subfunction in [@cyclic_transfer, @change_driven, @change_modify] do
    with {:ok, action, mode} <- decode_action(subfunction, sequence, operation),
         {:ok, interval, item_specs} <- decode_request_data(data, operation) do
      {:ok,
       %{
         action: action,
         mode: mode,
         job_id: sequence,
         interval: interval,
         item_specs: item_specs
       }}
    end
  end

  def decode_request(_request, operation), do: invalid_request(operation)

  defp request_data(item_specs, interval, operation) do
    case Enum.count_until(item_specs, 0x10000) do
      0x10000 ->
        invalid_items(operation, item_specs)

      count ->
        base = Map.fetch!(@base_codes, interval.base)

        data =
          IO.iodata_to_binary([<<count::unsigned-big-16, base, interval.factor>>, item_specs])

        if byte_size(data) <= 0xFFFF,
          do: {:ok, data},
          else: invalid_request(operation)
    end
  end

  defp decode_request_data(
         <<count::unsigned-big-16, base_code, factor, item_data::binary>>,
         operation
       )
       when count > 0 and factor > 0 do
    with {:ok, base} <- decode_base(base_code, operation),
         {:ok, item_specs, <<>>} <- decode_item_specs(item_data, count, operation, []) do
      {:ok,
       %CyclicModel.Interval{
         base: base,
         factor: factor,
         milliseconds: base_milliseconds(base) * factor
       }, item_specs}
    else
      {:ok, _items, remaining} ->
        Protocol.malformed(operation, %{trailing_bytes: byte_size(remaining)})

      {:error, %Error{} = error} ->
        {:error, error}

      {:more, needed} ->
        Protocol.malformed(operation, %{bytes_needed: needed})
    end
  end

  defp decode_request_data(_data, operation), do: invalid_request(operation)

  defp decode_item_specs(remaining, 0, _operation, items),
    do: {:ok, Enum.reverse(items), remaining}

  defp decode_item_specs(binary, _count, _operation, _items) when byte_size(binary) < 2,
    do: {:more, 2 - byte_size(binary)}

  defp decode_item_specs(
         <<0x12, specification_length, _rest::binary>> = binary,
         count,
         operation,
         items
       ) do
    total = specification_length + 2

    if byte_size(binary) < total do
      {:more, total - byte_size(binary)}
    else
      <<item::binary-size(^total), remaining::binary>> = binary

      case validate_raw_item(item) do
        :ok -> decode_item_specs(remaining, count - 1, operation, [item | items])
        {:error, reason} -> invalid_item(operation, length(items), reason)
      end
    end
  end

  defp decode_item_specs(_binary, _count, operation, _items), do: invalid_request(operation)

  defp decode_action(@cyclic_transfer, 0, _operation), do: {:ok, :subscribe, :cyclic}
  defp decode_action(@change_driven, 0, _operation), do: {:ok, :subscribe, :change_driven}

  defp decode_action(@change_modify, sequence, _operation) when sequence in 1..0xFF,
    do: {:ok, :modify, :change_driven}

  defp decode_action(_subfunction, _sequence, operation), do: invalid_request(operation)

  defp decode_base(0, _operation), do: {:ok, :hundred_milliseconds}
  defp decode_base(1, _operation), do: {:ok, :second}
  defp decode_base(2, _operation), do: {:ok, :ten_seconds}

  defp decode_base(code, operation),
    do: Protocol.error(operation, :invalid_cyclic_interval, details: %{time_base: code})

  defp setup_subfunction(:cyclic, _operation), do: {:ok, @cyclic_transfer}
  defp setup_subfunction(:change_driven, _operation), do: {:ok, @change_driven}

  defp setup_subfunction(mode, operation),
    do: Protocol.error(operation, :unsupported_cyclic_mode, details: %{mode: mode})

  defp validate_raw_item(<<0x12, length, syntax, body::binary>>)
       when syntax in [0x10, 0xB0] and byte_size(body) + 1 == length do
    validate_raw_syntax(syntax, length, body)
  end

  defp validate_raw_item(_item), do: {:error, :invalid_variable_specification}

  defp validate_raw_syntax(0x10, 0x0A, <<_::binary-size(9)>>), do: :ok

  defp validate_raw_syntax(0xB0, length, <<area_count, areas::binary>>)
       when area_count > 0 and length == 2 + area_count * 5 and
              byte_size(areas) == area_count * 5,
       do: :ok

  defp validate_raw_syntax(_syntax, _length, _body), do: {:error, :invalid_syntax_payload}

  defp decode_optional_snapshot(
         %UserData{payload: %Payload{data: <<>>}},
         _mode,
         _addresses,
         _item_count,
         _operation
       ) do
    {:ok, nil}
  end

  defp decode_optional_snapshot(response, mode, addresses, item_count, operation) do
    decode_event(
      response.payload.data,
      mode,
      addresses,
      item_count,
      response.parameter.sequence,
      response.parameter.subfunction,
      operation
    )
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp decode_event(
         <<count::unsigned-big-16, data::binary>> = raw,
         mode,
         addresses,
         expected_count,
         job_id,
         subfunction,
         operation
       ) do
    with true <- expected_count in [:any, count],
         {:ok, items, <<>>} <- decode_items(data, mode, addresses, count, operation, []) do
      {:ok,
       %CyclicModel.Event{
         job_id: job_id,
         subfunction: subfunction,
         items: items,
         raw: raw
       }}
    else
      false ->
        Protocol.malformed(operation, %{expected_items: expected_count, received_items: count})

      {:ok, _items, trailing} ->
        Protocol.malformed(operation, %{trailing_bytes: byte_size(trailing)})

      {:more, needed} ->
        Protocol.malformed(operation, %{bytes_needed: needed})

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        Protocol.malformed(operation, %{codec_reason: reason})
    end
  end

  defp decode_event(_data, _mode, _addresses, _count, _job_id, _subfunction, operation),
    do: Protocol.malformed(operation)

  defp decode_items(remaining, _mode, _addresses, 0, _operation, items),
    do: {:ok, Enum.reverse(items), remaining}

  defp decode_items(data, :change_driven, _addresses, count, operation, items) do
    with {:ok, item, remaining, item_raw} <- decode_query_item(data),
         {:ok, padding, remaining} <- consume_padding(remaining, item.data, count),
         {:ok, event_item} <- raw_event_item(item, padding, item_raw, operation) do
      decode_items(remaining, :change_driven, nil, count - 1, operation, [event_item | items])
    end
  end

  defp decode_items(data, :cyclic, addresses, count, operation, items) do
    case next_address(addresses) do
      {:ok, address, remaining_addresses} ->
        with {:ok, item, remaining, item_raw} <- decode_data_item(data),
             {:ok, padding, remaining} <- consume_padding(remaining, item.data, count),
             {:ok, event_item} <-
               fixed_event_item(item, address, padding, item_raw, operation) do
          decode_items(remaining, :cyclic, remaining_addresses, count - 1, operation, [
            event_item | items
          ])
        end

      :error ->
        {:error, :invalid_address_count}
    end
  end

  defp decode_items(_data, _mode, _addresses, _count, _operation, _items),
    do: {:error, :invalid_cyclic_mode}

  defp next_address([address | remaining]), do: {:ok, address, remaining}
  defp next_address(nil), do: {:ok, nil, nil}
  defp next_address(_addresses), do: :error

  defp decode_data_item(data) do
    before = byte_size(data)

    case DataItem.decode(data) do
      {:ok, item, remaining} ->
        consumed = before - byte_size(remaining)
        {:ok, item, remaining, binary_part(data, 0, consumed)}

      other ->
        other
    end
  end

  defp decode_query_item(binary) when byte_size(binary) < 4,
    do: {:more, 4 - byte_size(binary)}

  defp decode_query_item(
         <<return_code, transport_size, length::unsigned-big-16, rest::binary>> = binary
       ) do
    if byte_size(rest) < length do
      {:more, length - byte_size(rest)}
    else
      <<data::binary-size(^length), remaining::binary>> = rest
      consumed = byte_size(binary) - byte_size(remaining)

      item = %{
        return_code: return_code,
        transport_size: transport_size,
        encoded_length: length,
        data: data
      }

      {:ok, item, remaining, binary_part(binary, 0, consumed)}
    end
  end

  defp decode_query_item(_binary), do: {:error, :invalid_data_item}

  defp consume_padding(remaining, _data, 1), do: {:ok, <<>>, remaining}

  defp consume_padding(remaining, data, _count) when rem(byte_size(data), 2) == 0,
    do: {:ok, <<>>, remaining}

  defp consume_padding(<<padding, remaining::binary>>, _data, _count),
    do: {:ok, <<padding>>, remaining}

  defp consume_padding(<<>>, _data, _count), do: {:more, 1}

  defp fixed_event_item(item, nil, padding, item_raw, operation),
    do: raw_event_item(item, padding, item_raw, operation)

  defp fixed_event_item(item, address, padding, item_raw, operation) do
    case Protocol.item_result(operation, item.return_code) do
      :ok ->
        with :ok <- validate_typed_item(item, address, operation),
             {:ok, value} <- Data.decode(address.data_type, item.data, address.count) do
          {:ok, event_item(item, address, value, nil, padding, item_raw)}
        end

      {:error, %Error{} = error} ->
        {:ok, event_item(item, address, nil, error, padding, item_raw)}
    end
  end

  defp raw_event_item(item, padding, item_raw, operation) do
    error =
      case Protocol.item_result(operation, item.return_code) do
        :ok -> nil
        {:error, %Error{} = error} -> error
      end

    {:ok, event_item(item, nil, nil, error, padding, item_raw)}
  end

  defp event_item(item, address, value, error, padding, item_raw) do
    %EventItem{
      address: address,
      return_code: item.return_code,
      transport_size: item.transport_size,
      encoded_length: item.encoded_length,
      data: item.data,
      padding: padding,
      value: value,
      error: error,
      raw: item_raw <> padding
    }
  end

  defp validate_typed_item(item, address, operation) do
    expected_transports = DataItem.expected_transports(address)

    with true <- item.transport_size in expected_transports,
         {:ok, expected_size} <- Data.encoded_size(address.data_type, address.count),
         true <- byte_size(item.data) == expected_size,
         true <- item.encoded_length == expected_length(item.transport_size, expected_size) do
      :ok
    else
      _other ->
        Protocol.malformed(operation, %{
          expected_transports: expected_transports,
          received_transport: item.transport_size,
          payload_size: byte_size(item.data)
        })
    end
  end

  defp expected_length(transport, size) when transport in [:bit, :dinteger, :real, :octet],
    do: size

  defp expected_length(transport, size) when transport in [:byte, :integer], do: size * 8

  defp expected_indication_count(%CyclicModel.Subscription{typed?: true, item_specs: item_specs})
       when is_list(item_specs),
       do: length(item_specs)

  defp expected_indication_count(%CyclicModel.Subscription{}), do: :any

  defp validate_response_method(
         %UserData{parameter: %Parameter{method: @method_response} = parameter},
         operation
       ) do
    if Parameter.final_unit?(parameter), do: :ok, else: Protocol.malformed(operation)
  end

  defp validate_response_method(_response, operation), do: Protocol.malformed(operation)

  defp validate_indication(parameter, subscription, operation) do
    allowed_subfunctions = mode_subfunctions(subscription.mode)

    cond do
      parameter.method != @method_response or parameter.type != :indication ->
        Protocol.malformed(operation, %{
          method: parameter.method,
          userdata_type: parameter.type
        })

      parameter.function_group != :cyclic or
          parameter.subfunction not in allowed_subfunctions ->
        Protocol.malformed(operation, %{
          function_group: parameter.function_group,
          subfunction: parameter.subfunction
        })

      parameter.sequence != subscription.job_id ->
        Protocol.error(operation, :unexpected_subscription_job,
          details: %{expected: subscription.job_id, received: parameter.sequence}
        )

      parameter.error_code not in [nil, 0] ->
        Protocol.error(operation, :userdata_error, code: parameter.error_code)

      not Parameter.final_unit?(parameter) ->
        Protocol.malformed(operation, %{
          data_unit_reference: parameter.data_unit_reference,
          last_data_unit: parameter.last_data_unit,
          error_code: parameter.error_code
        })

      true ->
        :ok
    end
  end

  defp validate_event_payload(
         %Payload{return_code: @success, transport_size: @octet_string},
         _operation
       ),
       do: :ok

  defp validate_event_payload(%Payload{return_code: return_code}, operation),
    do: Protocol.item_result(operation, return_code)

  defp validate_snapshot_payload(
         %Payload{return_code: @success, transport_size: @octet_string},
         _operation
       ),
       do: :ok

  defp validate_snapshot_payload(_payload, operation), do: Protocol.malformed(operation)

  defp validate_unsubscribe_payload(
         %Payload{return_code: @success, transport_size: @octet_string, data: <<>>},
         _operation
       ),
       do: :ok

  defp validate_unsubscribe_payload(
         %Payload{return_code: @null_success, transport_size: @null, data: <<>>},
         _operation
       ),
       do: :ok

  defp validate_unsubscribe_payload(_payload, operation), do: Protocol.malformed(operation)

  defp build_interval(base, factor) do
    {:ok,
     %CyclicModel.Interval{
       base: base,
       factor: factor,
       milliseconds: base_milliseconds(base) * factor
     }}
  end

  defp base_milliseconds(:hundred_milliseconds), do: 100
  defp base_milliseconds(:second), do: 1_000
  defp base_milliseconds(:ten_seconds), do: 10_000

  defp invalid_interval(operation, value),
    do: Protocol.error(operation, :invalid_cyclic_interval, details: %{interval: value})

  defp invalid_request(operation), do: Protocol.error(operation, :invalid_cyclic_request)

  defp invalid_items(operation, items),
    do: Protocol.error(operation, :invalid_items, details: %{items: items})

  defp invalid_item(operation, index, reason),
    do: Protocol.error(operation, :invalid_cyclic_item, details: %{index: index, reason: reason})

  defp add_index(error, index, operation),
    do: %{error | operation: operation, details: Map.put(error.details, :index, index)}

  defp reverse_specs({:ok, specs}), do: {:ok, Enum.reverse(specs)}
  defp reverse_specs({:error, error}), do: {:error, error}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD209} = error, operation),
    do: %{error | operation: operation, reason: :object_not_found}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD241} = error, operation),
    do: %{error | operation: operation, reason: :access_denied}

  defp translate_error(%Error{reason: :userdata_error, code: 0xD804} = error, operation),
    do: %{error | operation: operation, reason: :invalid_cyclic_interval}

  defp translate_error(error, operation), do: %{error | operation: operation}
end
