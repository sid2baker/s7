defmodule S7.Protocol.PLCControl do
  @moduledoc """
  Pure codecs for classic CPU control Jobs.

  CPU stop uses Job function `0x29`. Warm/cold start, RAM-to-ROM copy,
  and memory compression use PI-Service function `0x28` with distinct
  parameter blocks.
  """

  alias S7.Error
  alias S7.Protocol.{Job, PDU}

  @type action ::
          :stop_cpu
          | :warm_start_cpu
          | :cold_start_cpu
          | :copy_ram_to_rom
          | :compress_memory

  @program "P_PROGRAM"

  @doc false
  @spec request(action(), atom()) :: {:ok, PDU.t()} | {:error, Error.t()}
  def request(action, operation) do
    case encode_parameters(action) do
      {:ok, parameters} -> {:ok, PDU.new(:job, 0, parameters)}
      :error -> invalid_action(operation, action)
    end
  end

  @doc false
  @spec decode_request(PDU.t(), atom()) :: {:ok, action()} | {:error, Error.t()}
  def decode_request(
        %PDU{header: %{rosctr: :job}, parameters: parameters, data: <<>>},
        operation
      ) do
    case parameters do
      <<0x29, 0::40, 9, @program>> -> {:ok, :stop_cpu}
      <<0x28, 0::48, 0xFD, 0::16, 9, @program>> -> {:ok, :warm_start_cpu}
      <<0x28, 0::48, 0xFD, 2::16, "C ", 9, @program>> -> {:ok, :cold_start_cpu}
      <<0x28, 0::48, 0xFD, 2::16, "EP", 5, "_MODU">> -> {:ok, :copy_ram_to_rom}
      <<0x28, 0::48, 0xFD, 0::16, 5, "_GARB">> -> {:ok, :compress_memory}
      _other -> malformed(operation, %{parameters: parameters})
    end
  end

  def decode_request(_pdu, operation), do: malformed(operation, %{})

  @doc false
  @spec decode_response(PDU.t(), action(), atom()) :: :ok | {:error, Error.t()}
  def decode_response(%PDU{} = pdu, action, operation) do
    with {:ok, function} <- response_function(action, operation),
         :ok <- Job.validate_response_header(pdu, operation),
         true <- pdu.parameters == <<function>>,
         <<>> <- pdu.data do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        malformed(operation, %{parameters: pdu.parameters, data_size: byte_size(pdu.data)})
    end
  end

  def decode_response(_pdu, _action, operation), do: malformed(operation, %{})

  defp encode_parameters(:stop_cpu), do: {:ok, <<0x29, 0::40, 9, @program>>}

  defp encode_parameters(:warm_start_cpu),
    do: {:ok, <<0x28, 0::48, 0xFD, 0::16, 9, @program>>}

  defp encode_parameters(:cold_start_cpu),
    do: {:ok, <<0x28, 0::48, 0xFD, 2::16, "C ", 9, @program>>}

  defp encode_parameters(:copy_ram_to_rom),
    do: {:ok, <<0x28, 0::48, 0xFD, 2::16, "EP", 5, "_MODU">>}

  defp encode_parameters(:compress_memory),
    do: {:ok, <<0x28, 0::48, 0xFD, 0::16, 5, "_GARB">>}

  defp encode_parameters(_action), do: :error

  defp response_function(:stop_cpu, _operation), do: {:ok, 0x29}

  defp response_function(action, _operation)
       when action in [:warm_start_cpu, :cold_start_cpu, :copy_ram_to_rom, :compress_memory],
       do: {:ok, 0x28}

  defp response_function(action, operation), do: invalid_action(operation, action)

  defp invalid_action(operation, action),
    do:
      {:error, Error.new(:client, operation, :invalid_control_action, details: %{action: action})}

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
