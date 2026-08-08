defmodule S7.Protocol.SetupCommunication do
  @moduledoc """
  Codec and request/response handling for Setup Communication (`0xF0`).
  """

  alias S7.Protocol
  alias S7.Protocol.PDU

  @function 0xF0
  @minimum_usable_pdu 32

  defstruct max_amq_calling: 1, max_amq_called: 1, pdu_length: 480

  @type t :: %__MODULE__{
          max_amq_calling: pos_integer(),
          max_amq_called: pos_integer(),
          pdu_length: pos_integer()
        }

  @doc """
  Encodes the eight-byte Setup Communication parameter block.
  """
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = setup) do
    validate_word!(setup.max_amq_calling, :max_amq_calling)
    validate_word!(setup.max_amq_called, :max_amq_called)
    validate_word!(setup.pdu_length, :pdu_length)

    <<@function, 0, setup.max_amq_calling::unsigned-big-16, setup.max_amq_called::unsigned-big-16,
      setup.pdu_length::unsigned-big-16>>
  end

  @doc """
  Decodes a Setup Communication parameter block.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :malformed_setup_communication}
  def decode(
        <<@function, _reserved, calling::unsigned-big-16, called::unsigned-big-16,
          pdu_length::unsigned-big-16>>
      )
      when calling > 0 and called > 0 and pdu_length >= @minimum_usable_pdu do
    {:ok,
     %__MODULE__{
       max_amq_calling: calling,
       max_amq_called: called,
       pdu_length: pdu_length
     }}
  end

  def decode(_parameters), do: {:error, :malformed_setup_communication}

  @doc """
  Builds a Setup Communication Job PDU.
  """
  @spec request(t(), 0..0xFFFF) :: PDU.t()
  def request(%__MODULE__{} = setup, reference) do
    PDU.new(:job, reference, encode(setup))
  end

  @doc """
  Validates and decodes a Setup Communication Ack-Data PDU.
  """
  @spec decode_response(PDU.t(), 0..0xFFFF) ::
          {:ok, t()} | {:error, S7.Error.t()}
  def decode_response(%PDU{} = pdu, expected_reference) do
    with :ok <- Protocol.validate_response(pdu, :setup_communication, expected_reference),
         :ok <- ensure_empty_data(pdu.data) do
      decode_parameters(pdu.parameters)
    end
  end

  defp decode_parameters(parameters) do
    case decode(parameters) do
      {:ok, setup} -> {:ok, setup}
      {:error, _reason} -> Protocol.malformed(:setup_communication)
    end
  end

  defp ensure_empty_data(<<>>), do: :ok
  defp ensure_empty_data(_data), do: Protocol.malformed(:setup_communication)

  defp validate_word!(value, _field) when value in 1..0xFFFF, do: :ok
  defp validate_word!(_value, field), do: raise(ArgumentError, "invalid #{field}")
end
