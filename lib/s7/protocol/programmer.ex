defmodule S7.Protocol.Programmer do
  @moduledoc """
  Raw-first codec for capture-backed classic programmer jobs.

  Only read-only subfunctions with packet evidence are accepted. Modify,
  force, breakpoint, memory-reset, and flash-LED commands are deliberately not
  exposed through this module.
  """

  alias S7.{Address, Data, Error}
  alias S7.Programmer, as: ProgrammerModel
  alias S7.Programmer.VariableStatus.Item
  alias S7.Protocol
  alias S7.Protocol.{PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}

  @setup_method 0x12
  @enable_job 0x0E
  @delete_job 0x0F
  @null 0x00
  @null_success 0x0A
  @octet_string 0x09
  @success 0xFF

  @services %{
    0x01 => :block_status,
    0x02 => :variable_status,
    0x03 => :output_istack,
    0x04 => :output_bstack,
    0x05 => :output_lstack,
    0x10 => :read_job_list,
    0x11 => :read_job,
    0x13 => :block_status_v2
  }

  @variable_status_parameters <<
    0::16,
    1::16,
    0::16,
    0x12::16,
    1::16,
    1::16,
    1::16,
    1::16,
    1::16,
    0x0200::16
  >>

  @management_parameters <<
    0::16,
    0::16,
    1::16,
    0::16,
    0::16,
    1::16,
    1::16,
    1::16,
    1::16,
    0::16
  >>

  defmodule Job do
    @moduledoc """
    Validated state for one temporary classic programmer job.

    The PLC assigns `sequence` in the setup response; callers must use it for
    enable, indication correlation, and deletion.
    """

    @enforce_keys [:service, :subfunction, :setup_parameters, :setup_data]
    defstruct [:service, :subfunction, :setup_parameters, :setup_data, :sequence]

    @type t :: %__MODULE__{
            service: ProgrammerModel.Event.service(),
            subfunction: byte(),
            setup_parameters: binary(),
            setup_data: binary(),
            sequence: byte() | nil
          }
  end

  @type limits :: %{timeout: pos_integer(), step_timeout: pos_integer()}

  @doc """
  Validates options for one bounded programmer job.
  """
  @spec validate_options(term(), atom()) :: {:ok, limits()} | {:error, Error.t()}
  def validate_options(opts, operation) when is_list(opts) and is_atom(operation) do
    allowed = [:timeout, :step_timeout]

    with true <- Keyword.keyword?(opts),
         nil <- Enum.find(Keyword.keys(opts), &(&1 not in allowed)),
         {:ok, timeout} <- positive_option(opts, :timeout, 5_000, operation),
         {:ok, step_timeout} <- positive_option(opts, :step_timeout, timeout, operation) do
      {:ok, %{timeout: timeout, step_timeout: step_timeout}}
    else
      false -> invalid_options(operation, opts)
      option when is_atom(option) -> invalid_option(operation, option, Keyword.get(opts, option))
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def validate_options(opts, operation) do
    operation = if is_atom(operation), do: operation, else: :programmer_diagnostic
    invalid_options(operation, opts)
  end

  @doc """
  Builds a read-only programmer job setup request around opaque service bytes.
  """
  @spec start_request(ProgrammerModel.Event.service() | byte(), binary(), binary(), atom()) ::
          {:ok, UserData.t(), Job.t()} | {:error, Error.t()}
  def start_request(subfunction, parameters, data, operation \\ :programmer_diagnostic)

  def start_request(subfunction, parameters, data, operation)
      when is_binary(parameters) and is_binary(data) and is_atom(operation) do
    with {:ok, subfunction, service} <- service(subfunction, operation),
         {:ok, encoded} <- encode_service_data(parameters, data, operation),
         {:ok, request} <-
           UserData.request(:programmer, subfunction, encoded,
             method: @setup_method,
             data_unit_reference: 0,
             last_data_unit: 0,
             error_code: 0
           ) do
      {:ok, request,
       %Job{
         service: service,
         subfunction: subfunction,
         setup_parameters: parameters,
         setup_data: data
       }}
    end
  end

  def start_request(_subfunction, _parameters, _data, operation),
    do: invalid_request(operation)

  @doc """
  Builds the capture-backed variable-status setup for normalized addresses.
  """
  @spec variable_status_request([Address.t()], atom()) ::
          {:ok, UserData.t(), Job.t()} | {:error, Error.t()}
  def variable_status_request(addresses, operation \\ :variable_status)

  def variable_status_request(addresses, operation)
      when is_list(addresses) and addresses != [] and is_atom(operation) do
    case Enum.count_until(addresses, 0x10000) do
      0x10000 ->
        invalid_request(operation)

      count ->
        with {:ok, encoded_addresses} <- encode_variable_addresses(addresses, operation) do
          data = IO.iodata_to_binary([<<count::unsigned-big-16>>, encoded_addresses])
          start_request(0x02, @variable_status_parameters, data, operation)
        end
    end
  end

  def variable_status_request(_addresses, operation), do: invalid_request(operation)

  @doc """
  Decodes a null-success setup response and records the PLC-assigned job sequence.
  """
  @spec decode_start_response(PDU.t(), UserData.t(), Job.t(), 0..0xFFFF, atom()) ::
          {:ok, Job.t()} | {:error, Error.t()}
  def decode_start_response(pdu, request, %Job{} = job, reference, operation) do
    with {:ok, response} <-
           UserData.decode_response(pdu, request, reference, allow_null_success: true),
         :ok <- validate_null_response(response, operation),
         sequence when sequence in 1..0xFF <- response.parameter.sequence do
      {:ok, %{job | sequence: sequence}}
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
      _other -> malformed(operation, %{job_sequence: :invalid})
    end
  end

  @doc false
  @spec enable_request(Job.t(), atom()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def enable_request(%Job{sequence: sequence, subfunction: subfunction}, operation)
      when sequence in 1..0xFF do
    management_request(@enable_job, <<subfunction, sequence>>, operation)
  end

  def enable_request(_job, operation), do: invalid_request(operation)

  @doc false
  @spec delete_request(Job.t(), atom()) :: {:ok, UserData.t()} | {:error, Error.t()}
  def delete_request(%Job{sequence: sequence, subfunction: subfunction}, operation)
      when sequence in 1..0xFF do
    management_request(@delete_job, <<1::16, subfunction, sequence>>, operation)
  end

  def delete_request(_job, operation), do: invalid_request(operation)

  @doc false
  @spec decode_management_response(PDU.t(), UserData.t(), 0..0xFFFF, atom()) ::
          :ok | {:error, Error.t()}
  def decode_management_response(pdu, request, reference, operation) do
    with {:ok, response} <-
           UserData.decode_response(pdu, request, reference, allow_null_success: true),
         :ok <- validate_null_response(response, operation) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, translate_error(error, operation)}
    end
  end

  @doc """
  Decodes one indication for a known programmer job without interpreting its records.
  """
  @spec decode_indication(UserData.t(), Job.t(), atom()) ::
          {:ok, ProgrammerModel.Event.t()} | {:error, Error.t()}
  def decode_indication(
        %UserData{
          parameter: %Parameter{} = parameter,
          payload: %Payload{} = payload
        },
        %Job{} = job,
        operation
      ) do
    with :ok <- validate_indication_identity(parameter, job, operation),
         :ok <- validate_indication_payload(payload, operation),
         {:ok, parameters, data} <- decode_service_data(payload.data, operation) do
      {:ok,
       %ProgrammerModel.Event{
         service: job.service,
         subfunction: job.subfunction,
         sequence: job.sequence,
         parameters: parameters,
         data: data,
         raw: payload.data
       }}
    end
  end

  def decode_indication(_message, _job, operation), do: malformed(operation)

  @doc """
  Decodes variable-status item records and preserves every item byte.
  """
  @spec decode_variable_status(ProgrammerModel.Event.t(), [Address.t()], atom()) ::
          {:ok, ProgrammerModel.VariableStatus.t()} | {:error, Error.t()}
  def decode_variable_status(event, addresses, operation \\ :variable_status)

  def decode_variable_status(
        %ProgrammerModel.Event{
          service: :variable_status,
          data: <<count::unsigned-big-16, rest::binary>>
        } =
          event,
        addresses,
        operation
      )
      when is_list(addresses) and is_atom(operation) do
    with true <- count == length(addresses),
         {:ok, items, <<>>} <- decode_variable_items(rest, addresses, operation, []) do
      {:ok,
       %ProgrammerModel.VariableStatus{
         sequence: event.sequence,
         parameters: event.parameters,
         items: items,
         raw: event.raw
       }}
    else
      false -> malformed(operation, %{expected_items: length(addresses), received_items: count})
      {:ok, _items, trailing} -> malformed(operation, %{trailing_bytes: byte_size(trailing)})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def decode_variable_status(_event, _addresses, operation), do: malformed(operation)

  @doc false
  @spec encode_service_data(binary(), binary(), atom()) :: {:ok, binary()} | {:error, Error.t()}
  def encode_service_data(parameters, data, _operation)
      when is_binary(parameters) and is_binary(data) and byte_size(parameters) <= 0xFFFF and
             byte_size(data) <= 0xFFFF do
    {:ok,
     <<byte_size(parameters)::unsigned-big-16, byte_size(data)::unsigned-big-16,
       parameters::binary, data::binary>>}
  end

  def encode_service_data(_parameters, _data, operation), do: invalid_request(operation)

  @doc false
  @spec decode_service_data(binary(), atom()) ::
          {:ok, binary(), binary()} | {:error, Error.t()}
  def decode_service_data(
        <<parameter_size::unsigned-big-16, data_size::unsigned-big-16, rest::binary>>,
        operation
      ) do
    expected = parameter_size + data_size

    if byte_size(rest) == expected do
      <<parameters::binary-size(^parameter_size), data::binary-size(^data_size)>> = rest
      {:ok, parameters, data}
    else
      malformed(operation, %{expected_size: expected + 4, received_size: byte_size(rest) + 4})
    end
  end

  def decode_service_data(binary, operation) when is_binary(binary),
    do: malformed(operation, %{received_size: byte_size(binary)})

  def decode_service_data(_binary, operation), do: malformed(operation)

  defp management_request(subfunction, data, operation) do
    with {:ok, encoded} <- encode_service_data(@management_parameters, data, operation) do
      UserData.request(:programmer, subfunction, encoded,
        method: @setup_method,
        data_unit_reference: 0,
        last_data_unit: 0,
        error_code: 0
      )
    end
  end

  defp validate_null_response(
         %UserData{
           parameter: %Parameter{
             method: @setup_method,
             type: :response,
             data_unit_reference: data_unit_reference,
             last_data_unit: 0,
             error_code: 0
           },
           payload: %Payload{return_code: @null_success, transport_size: @null, data: <<>>}
         },
         _operation
       )
       when data_unit_reference in 0..0xFF,
       do: :ok

  defp validate_null_response(_response, operation), do: malformed(operation)

  defp validate_indication_identity(parameter, job, operation) do
    with :ok <- validate_indication_role(parameter, operation),
         :ok <- validate_indication_service(parameter, job, operation),
         :ok <- validate_indication_sequence(parameter, job, operation) do
      validate_indication_extension(parameter, operation)
    end
  end

  defp validate_indication_role(%Parameter{method: @setup_method, type: :indication}, _operation),
    do: :ok

  defp validate_indication_role(parameter, operation),
    do: malformed(operation, %{userdata_type: parameter.type, method: parameter.method})

  defp validate_indication_service(
         %Parameter{function_group: :programmer, subfunction: subfunction},
         %Job{subfunction: subfunction},
         _operation
       ),
       do: :ok

  defp validate_indication_service(parameter, job, operation),
    do:
      malformed(operation, %{
        expected_service: {:programmer, job.subfunction},
        received_service: {parameter.function_group, parameter.subfunction}
      })

  defp validate_indication_sequence(
         %Parameter{sequence: sequence},
         %Job{sequence: sequence},
         _operation
       ),
       do: :ok

  defp validate_indication_sequence(parameter, job, operation),
    do:
      malformed(operation, %{
        expected_sequence: job.sequence,
        received_sequence: parameter.sequence
      })

  defp validate_indication_extension(
         %Parameter{
           data_unit_reference: data_unit_reference,
           last_data_unit: last_data_unit,
           error_code: error_code
         },
         _operation
       )
       when data_unit_reference in [nil, 0] and last_data_unit in [nil, 0] and
              error_code in [nil, 0],
       do: :ok

  defp validate_indication_extension(_parameter, operation),
    do: malformed(operation, %{parameter_extension: :invalid})

  defp validate_indication_payload(
         %Payload{return_code: @success, transport_size: @octet_string},
         _operation
       ),
       do: :ok

  defp validate_indication_payload(payload, operation),
    do:
      malformed(operation, %{
        return_code: payload.return_code,
        transport_size: payload.transport_size
      })

  defp encode_variable_addresses(addresses, operation) do
    addresses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {address, index}, {:ok, encoded} ->
      case encode_variable_address(address, operation) do
        {:ok, item} ->
          {:cont, {:ok, [encoded, item]}}

        {:error, %Error{} = error} ->
          error = %{error | details: Map.put(error.details, :item_index, index)}
          {:halt, {:error, error}}
      end
    end)
  end

  defp encode_variable_address(%Address{} = address, operation) do
    with {:ok, address} <- Address.validate(address),
         {:ok, area_code, repetition, offset} <- variable_address_fields(address, operation),
         true <- offset in 0..0xFFFF do
      {:ok,
       <<area_code, repetition, address.db_number::unsigned-big-16, offset::unsigned-big-16>>}
    else
      false -> invalid_variable_address(operation, address, :address_out_of_range)
      {:error, %Error{} = error} -> {:error, %{error | operation: operation}}
    end
  end

  defp encode_variable_address(address, operation),
    do: invalid_variable_address(operation, address, :invalid_address)

  defp variable_address_fields(%Address{area: area, data_type: :bit} = address, _operation)
       when area in [:markers, :inputs, :outputs, :db] do
    {:ok, area_base(area), address.bit_offset, address.byte_offset}
  end

  defp variable_address_fields(%Address{area: :peripheral, data_type: :bit} = address, operation),
    do: invalid_variable_address(operation, address, :data_type_not_supported)

  defp variable_address_fields(%Address{area: area} = address, operation)
       when area in [:markers, :inputs, :outputs, :peripheral, :db] do
    with {:ok, width} <- Data.size(address.data_type),
         true <- width in [1, 2, 4],
         true <- address.count in 1..0xFF do
      {:ok, area_base(area) + width_code(width), address.count, address.byte_offset}
    else
      _other -> invalid_variable_address(operation, address, :data_type_not_supported)
    end
  end

  defp variable_address_fields(%Address{area: :timers} = address, operation),
    do: validate_element_address(address, 0x54, operation)

  defp variable_address_fields(%Address{area: :counters} = address, operation),
    do: validate_element_address(address, 0x64, operation)

  defp variable_address_fields(address, operation),
    do: invalid_variable_address(operation, address, :unsupported_area)

  defp validate_element_address(address, code, operation) do
    if address.count in 1..0xFF do
      {:ok, code, address.count, address.element_offset}
    else
      invalid_variable_address(operation, address, :data_type_not_supported)
    end
  end

  defp area_base(:markers), do: 0x00
  defp area_base(:inputs), do: 0x10
  defp area_base(:outputs), do: 0x20
  defp area_base(:peripheral), do: 0x30
  defp area_base(:db), do: 0x70

  defp width_code(1), do: 1
  defp width_code(2), do: 2
  defp width_code(4), do: 3

  defp decode_variable_items(remaining, [], _operation, items),
    do: {:ok, Enum.reverse(items), remaining}

  defp decode_variable_items(binary, [address | addresses], operation, items) do
    with {:ok, item, remaining} <- decode_variable_item(binary, address, operation) do
      decode_variable_items(remaining, addresses, operation, [item | items])
    end
  end

  defp decode_variable_item(
         <<return_code, transport_size, encoded_length::unsigned-big-16, rest::binary>> = raw,
         address,
         operation
       ) do
    payload_size = variable_payload_size(transport_size, encoded_length)
    padding_size = rem(payload_size, 2)
    required = payload_size + padding_size

    if byte_size(rest) >= required do
      <<data::binary-size(^payload_size), padding::binary-size(^padding_size), remaining::binary>> =
        rest

      item_raw = binary_part(raw, 0, 4 + required)

      with :ok <- validate_padding(padding, operation),
           {:ok, value, error} <- decode_variable_value(return_code, data, address, operation) do
        {:ok,
         %Item{
           address: address,
           return_code: return_code,
           transport_size: transport_size,
           encoded_length: encoded_length,
           data: data,
           padding: padding,
           value: value,
           error: error,
           raw: item_raw
         }, remaining}
      end
    else
      malformed(operation, %{bytes_needed: required - byte_size(rest)})
    end
  end

  defp decode_variable_item(binary, _address, operation) when is_binary(binary),
    do: malformed(operation, %{bytes_needed: max(4 - byte_size(binary), 0)})

  defp variable_payload_size(transport_size, encoded_length)
       when transport_size in [0x03, 0x04, 0x05],
       do: div(encoded_length + 7, 8)

  defp variable_payload_size(_transport_size, encoded_length), do: encoded_length

  defp validate_padding(<<>>, _operation), do: :ok
  defp validate_padding(<<0>>, _operation), do: :ok
  defp validate_padding(padding, operation), do: malformed(operation, %{padding: padding})

  defp decode_variable_value(@success, data, address, operation) do
    case Data.decode(address.data_type, data, address.count) do
      {:ok, value} ->
        {:ok, value, nil}

      {:error, %Error{} = error} ->
        malformed(operation, %{value_codec_reason: error.reason, address: address})
    end
  end

  defp decode_variable_value(return_code, _data, _address, operation) do
    case Protocol.item_result(operation, return_code) do
      {:error, %Error{} = error} -> {:ok, nil, error}
      :ok -> {:ok, nil, nil}
    end
  end

  defp service(subfunction, operation) when is_integer(subfunction) do
    case @services do
      %{^subfunction => service} -> {:ok, subfunction, service}
      _other -> invalid_subfunction(subfunction, operation)
    end
  end

  defp service(service, operation) when is_atom(service) do
    case Enum.find(@services, fn {_subfunction, name} -> name == service end) do
      {subfunction, ^service} -> {:ok, subfunction, service}
      nil -> invalid_subfunction(service, operation)
    end
  end

  defp service(subfunction, operation), do: invalid_subfunction(subfunction, operation)

  defp positive_option(opts, option, default, operation) do
    value = Keyword.get(opts, option, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      invalid_option(operation, option, value)
    end
  end

  defp translate_error(%Error{reason: :userdata_error, code: 0xD241} = error, operation),
    do: %{error | operation: operation, reason: :access_denied}

  defp translate_error(%Error{} = error, operation), do: %{error | operation: operation}

  defp invalid_subfunction(subfunction, operation),
    do:
      {:error,
       Error.new(:client, operation, :unsupported_programmer_subfunction,
         details: %{subfunction: subfunction, allowed: Map.keys(@services) |> Enum.sort()}
       )}

  defp invalid_variable_address(operation, address, reason),
    do: {:error, Error.new(:address, operation, reason, details: %{address: address})}

  defp invalid_request(operation),
    do: {:error, Error.new(:client, operation, :invalid_programmer_request)}

  defp invalid_options(operation, opts),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}

  defp invalid_option(operation, option, value),
    do:
      {:error,
       Error.new(:client, operation, :invalid_option, details: %{option: option, value: value})}

  defp malformed(operation, details \\ %{}),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
