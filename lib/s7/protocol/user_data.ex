defmodule S7.Protocol.UserData do
  @moduledoc """
  Codec for the common classic S7 userdata envelope.

  Service-specific codecs own the bytes inside `Payload.data`. This module
  validates the generic parameter item, payload header, ROSCTR, PDU reference,
  and service identity without interpreting service-specific content.
  """

  alias S7.Error
  alias S7.Protocol
  alias S7.Protocol.PDU
  alias S7.Protocol.UserData.{Parameter, Payload}

  @function 0x00
  @item_count 0x01
  @variable_specification 0x12

  @type_codes %{indication: 0, request: 1, response: 2}
  @code_to_type Map.new(@type_codes, fn {type, code} -> {code, type} end)

  @group_codes %{
    programmer: 0x01,
    cyclic: 0x02,
    blocks: 0x03,
    cpu: 0x04,
    security: 0x05,
    bsend: 0x06,
    time: 0x07,
    data_record_routing: 0x20,
    nc_programming: 0x3F
  }

  @code_to_group Map.new(@group_codes, fn {group, code} -> {code, group} end)

  @enforce_keys [:parameter, :payload]
  defstruct [:parameter, :payload]

  @type t :: %__MODULE__{parameter: Parameter.t(), payload: Payload.t()}

  @type codec_error ::
          :invalid_userdata
          | :invalid_userdata_parameter
          | :invalid_userdata_payload
          | :unsupported_userdata_type
          | :malformed_userdata_parameter
          | :malformed_userdata_payload
          | :trailing_userdata_payload

  @doc """
  Builds one generic userdata request with the conventional initial method.
  """
  @spec request(Parameter.function_group(), byte(), binary(), keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def request(function_group, subfunction, data, opts \\ [])

  def request(function_group, subfunction, data, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      build_request(function_group, subfunction, data, opts)
    else
      Protocol.error(:userdata, :invalid_userdata)
    end
  end

  def request(_function_group, _subfunction, _data, _opts),
    do: Protocol.error(:userdata, :invalid_userdata)

  defp build_request(function_group, subfunction, data, opts) do
    parameter = %Parameter{
      method: Keyword.get(opts, :method, 0x11),
      type: :request,
      function_group: function_group,
      subfunction: subfunction,
      sequence: Keyword.get(opts, :sequence, 0),
      data_unit_reference: Keyword.get(opts, :data_unit_reference),
      last_data_unit: Keyword.get(opts, :last_data_unit),
      error_code: Keyword.get(opts, :error_code)
    }

    payload = %Payload{
      return_code: Keyword.get(opts, :return_code, 0xFF),
      transport_size: Keyword.get(opts, :transport_size, 0x09),
      data: data
    }

    message = %__MODULE__{parameter: parameter, payload: payload}

    case validate(message) do
      :ok -> {:ok, message}
      {:error, reason} -> Protocol.error(:userdata, reason)
    end
  end

  @doc """
  Encodes a generic userdata message into an S7 PDU.
  """
  @spec to_pdu(t(), 0..0xFFFF) :: {:ok, PDU.t()} | {:error, Error.t()}
  def to_pdu(%__MODULE__{} = message, reference) when reference in 0..0xFFFF do
    with :ok <- validate(message),
         {:ok, parameters} <- encode_parameter(message.parameter),
         {:ok, data} <- encode_payload(message.payload) do
      {:ok, PDU.new(:userdata, reference, parameters, data)}
    else
      {:error, reason} -> Protocol.error(:userdata, reason)
    end
  end

  def to_pdu(_message, _reference), do: Protocol.error(:userdata, :invalid_userdata)

  @doc """
  Decodes a generic userdata envelope from an S7 PDU.
  """
  @spec from_pdu(PDU.t()) :: {:ok, t()} | {:error, Error.t()}
  def from_pdu(%PDU{header: %{rosctr: :userdata}} = pdu) do
    with {:ok, parameter} <- decode_parameter(pdu.parameters),
         {:ok, payload} <- decode_payload(pdu.data) do
      {:ok, %__MODULE__{parameter: parameter, payload: payload}}
    else
      {:more, needed} -> Protocol.malformed(:userdata, %{bytes_needed: needed})
      {:error, reason} -> Protocol.malformed(:userdata, %{codec_reason: reason})
    end
  end

  def from_pdu(%PDU{header: header}),
    do: Protocol.error(:userdata, :unexpected_rosctr, details: %{rosctr: header.rosctr})

  def from_pdu(_pdu), do: Protocol.malformed(:userdata)

  @doc """
  Validates and decodes a response for a previously encoded userdata request.
  """
  @spec decode_response(PDU.t(), t(), 0..0xFFFF) :: {:ok, t()} | {:error, Error.t()}
  def decode_response(%PDU{} = pdu, %__MODULE__{} = request, expected_reference) do
    with :ok <- validate_reference(pdu, expected_reference),
         {:ok, response} <- from_pdu(pdu),
         :ok <- validate_response_identity(response, request),
         :ok <- validate_parameter_error(response.parameter),
         :ok <- validate_return_code(response.payload.return_code) do
      {:ok, response}
    end
  end

  @doc """
  Encodes the fixed userdata parameter envelope.
  """
  @spec encode_parameter(Parameter.t()) :: {:ok, binary()} | {:error, codec_error()}
  def encode_parameter(%Parameter{} = parameter) do
    with {:ok, type} <- encode_type(parameter.type),
         {:ok, group} <- encode_group(parameter.function_group),
         :ok <- validate_byte(parameter.method),
         :ok <- validate_byte(parameter.subfunction),
         :ok <- validate_byte(parameter.sequence),
         {:ok, extension} <- encode_extension(parameter) do
      item =
        <<parameter.method, type::2, group::6, parameter.subfunction, parameter.sequence,
          extension::binary>>

      {:ok, <<@function, @item_count, @variable_specification, byte_size(item), item::binary>>}
    else
      {:error, _reason} -> {:error, :invalid_userdata_parameter}
    end
  end

  def encode_parameter(_parameter), do: {:error, :invalid_userdata_parameter}

  @doc """
  Decodes one complete userdata parameter envelope.
  """
  @spec decode_parameter(binary()) ::
          {:ok, Parameter.t()} | {:more, pos_integer()} | {:error, codec_error()}
  def decode_parameter(binary) when is_binary(binary) and byte_size(binary) < 4,
    do: {:more, 4 - byte_size(binary)}

  def decode_parameter(
        <<@function, @item_count, @variable_specification, item_length, rest::binary>>
      )
      when item_length in [4, 8] do
    if byte_size(rest) < item_length do
      {:more, item_length - byte_size(rest)}
    else
      case rest do
        <<item::binary-size(item_length)>> -> decode_parameter_item(item)
        _trailing -> {:error, :malformed_userdata_parameter}
      end
    end
  end

  def decode_parameter(binary) when is_binary(binary),
    do: {:error, :malformed_userdata_parameter}

  def decode_parameter(_binary), do: {:error, :invalid_userdata_parameter}

  @doc """
  Encodes the common userdata payload header and service bytes.
  """
  @spec encode_payload(Payload.t()) :: {:ok, binary()} | {:error, codec_error()}
  def encode_payload(%Payload{
        return_code: return_code,
        transport_size: transport_size,
        data: data
      })
      when return_code in 0..0xFF and transport_size in 0..0xFF and is_binary(data) and
             byte_size(data) <= 0xFFFF do
    {:ok, <<return_code, transport_size, byte_size(data)::unsigned-big-16, data::binary>>}
  end

  def encode_payload(_payload), do: {:error, :invalid_userdata_payload}

  @doc """
  Decodes one complete userdata payload.
  """
  @spec decode_payload(binary()) ::
          {:ok, Payload.t()} | {:more, pos_integer()} | {:error, codec_error()}
  def decode_payload(binary) when is_binary(binary) and byte_size(binary) < 4,
    do: {:more, 4 - byte_size(binary)}

  def decode_payload(<<return_code, transport_size, length::unsigned-big-16, rest::binary>>) do
    cond do
      byte_size(rest) < length ->
        {:more, length - byte_size(rest)}

      byte_size(rest) > length ->
        {:error, :trailing_userdata_payload}

      true ->
        {:ok, %Payload{return_code: return_code, transport_size: transport_size, data: rest}}
    end
  end

  def decode_payload(_binary), do: {:error, :invalid_userdata_payload}

  @doc false
  @spec validate(t()) :: :ok | {:error, codec_error()}
  def validate(%__MODULE__{parameter: %Parameter{} = parameter, payload: %Payload{} = payload}) do
    with {:ok, _encoded} <- encode_parameter(parameter),
         {:ok, _encoded} <- encode_payload(payload) do
      :ok
    end
  end

  def validate(_message), do: {:error, :invalid_userdata}

  defp decode_parameter_item(<<method, type::2, group::6, subfunction, sequence>>) do
    build_parameter(method, type, group, subfunction, sequence, nil, nil, nil)
  end

  defp decode_parameter_item(
         <<method, type::2, group::6, subfunction, sequence, data_unit_reference, last_data_unit,
           error_code::unsigned-big-16>>
       ) do
    build_parameter(
      method,
      type,
      group,
      subfunction,
      sequence,
      data_unit_reference,
      last_data_unit,
      error_code
    )
  end

  defp build_parameter(
         method,
         type_code,
         group_code,
         subfunction,
         sequence,
         data_unit_reference,
         last_data_unit,
         error_code
       ) do
    with {:ok, type} <- decode_type(type_code) do
      {:ok,
       %Parameter{
         method: method,
         type: type,
         function_group: Map.get(@code_to_group, group_code, group_code),
         subfunction: subfunction,
         sequence: sequence,
         data_unit_reference: data_unit_reference,
         last_data_unit: last_data_unit,
         error_code: error_code
       }}
    end
  end

  defp encode_extension(%Parameter{
         data_unit_reference: nil,
         last_data_unit: nil,
         error_code: nil
       }),
       do: {:ok, <<>>}

  defp encode_extension(%Parameter{
         data_unit_reference: reference,
         last_data_unit: last,
         error_code: error
       })
       when reference in 0..0xFF and last in 0..0xFF and error in 0..0xFFFF,
       do: {:ok, <<reference, last, error::unsigned-big-16>>}

  defp encode_extension(_parameter), do: {:error, :invalid_userdata_parameter}

  defp encode_type(type) do
    case @type_codes do
      %{^type => code} -> {:ok, code}
      _other -> {:error, :unsupported_userdata_type}
    end
  end

  defp decode_type(code) do
    case @code_to_type do
      %{^code => type} -> {:ok, type}
      _other -> {:error, :unsupported_userdata_type}
    end
  end

  defp encode_group(group) when group in 0..0x3F, do: {:ok, group}

  defp encode_group(group) do
    case @group_codes do
      %{^group => code} -> {:ok, code}
      _other -> {:error, :invalid_userdata_parameter}
    end
  end

  defp validate_reference(%PDU{header: header}, expected_reference) do
    cond do
      header.rosctr != :userdata ->
        Protocol.error(:userdata, :unexpected_rosctr, details: %{rosctr: header.rosctr})

      header.pdu_reference != expected_reference ->
        Protocol.error(:userdata, :unexpected_pdu_reference,
          details: %{expected: expected_reference, received: header.pdu_reference}
        )

      true ->
        :ok
    end
  end

  defp validate_response_identity(response, request) do
    response_parameter = response.parameter
    request_parameter = request.parameter

    cond do
      response_parameter.type != :response ->
        Protocol.error(:userdata, :unexpected_userdata_type,
          details: %{type: response_parameter.type}
        )

      response_parameter.function_group != request_parameter.function_group or
          response_parameter.subfunction != request_parameter.subfunction ->
        Protocol.error(:userdata, :unexpected_userdata_service,
          details: %{
            expected: {request_parameter.function_group, request_parameter.subfunction},
            received: {response_parameter.function_group, response_parameter.subfunction}
          }
        )

      true ->
        :ok
    end
  end

  defp validate_parameter_error(%Parameter{error_code: error_code})
       when error_code in [nil, 0],
       do: :ok

  defp validate_parameter_error(%Parameter{error_code: error_code}),
    do: Protocol.error(:userdata, :userdata_error, code: error_code)

  defp validate_return_code(return_code), do: Protocol.item_result(:userdata, return_code)

  defp validate_byte(value) when value in 0..0xFF, do: :ok
  defp validate_byte(_value), do: {:error, :invalid_userdata_parameter}
end
