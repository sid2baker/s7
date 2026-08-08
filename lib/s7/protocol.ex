defmodule S7.Protocol do
  @moduledoc false

  alias S7.Error
  alias S7.Protocol.PDU

  @item_errors %{
    0x01 => :hardware_fault,
    0x03 => :access_denied,
    0x05 => :address_out_of_range,
    0x06 => :data_type_not_supported,
    0x07 => :data_type_inconsistent,
    0x0A => :object_not_found
  }

  @spec validate_response(PDU.t(), atom(), 0..0xFFFF) :: :ok | {:error, Error.t()}
  def validate_response(%PDU{header: header}, operation, expected_reference) do
    cond do
      header.rosctr != :ack_data ->
        error(operation, :unexpected_rosctr, details: %{rosctr: header.rosctr})

      header.pdu_reference != expected_reference ->
        error(operation, :unexpected_pdu_reference,
          details: %{expected: expected_reference, received: header.pdu_reference}
        )

      header.error_class not in [nil, 0] or header.error_code not in [nil, 0] ->
        code = {header.error_class || 0, header.error_code || 0}
        error(operation, :protocol_error, code: code)

      true ->
        :ok
    end
  end

  def validate_response(_pdu, operation, _expected_reference),
    do: error(operation, :malformed_response)

  @spec item_result(atom(), byte()) :: :ok | {:error, Error.t()}
  def item_result(_operation, 0xFF), do: :ok

  def item_result(operation, code) when code in 0..0xFF do
    reason = Map.get(@item_errors, code, :plc_error)
    error(operation, reason, code: code)
  end

  @spec malformed(atom(), map()) :: {:error, Error.t()}
  def malformed(operation, details \\ %{}),
    do: error(operation, :malformed_response, details: details)

  @spec error(atom(), atom(), keyword()) :: {:error, Error.t()}
  def error(operation, reason, opts \\ []),
    do: {:error, Error.new(:s7, operation, reason, opts)}
end
