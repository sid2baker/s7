defmodule S7.Protocol.Job do
  @moduledoc false

  import Bitwise

  alias S7.Error
  alias S7.Protocol.PDU

  @complete_rejections [
    :access_denied,
    :object_not_found,
    :invalid_block,
    :resource_busy,
    :operation_not_supported,
    :plc_error
  ]

  @spec validate_response_header(PDU.t(), atom()) :: :ok | {:error, Error.t()}
  def validate_response_header(%PDU{header: header}, operation) do
    code = (header.error_class || 0) <<< 8 ||| (header.error_code || 0)

    cond do
      code != 0 -> plc_error(operation, code)
      header.rosctr != :ack_data -> malformed(operation, %{rosctr: header.rosctr})
      true -> :ok
    end
  end

  @spec complete_rejection?(Error.t()) :: boolean()
  def complete_rejection?(%Error{reason: reason}), do: reason in @complete_rejections

  @spec plc_error(atom(), 0..0xFFFF) :: {:error, Error.t()}
  def plc_error(operation, code) do
    reason =
      case code do
        0xD241 -> :access_denied
        value when value in [0xD209, 0xD20E] -> :object_not_found
        value when value in [0xD20C, 0xD20D, 0xD210, 0xD212, 0xD219, 0xD220] -> :invalid_block
        value when value in [0xD2A1, 0xD2A4] -> :resource_busy
        value when value in [0xD201, 0xD202, 0xD2C2] -> :operation_not_supported
        _other -> :plc_error
      end

    {:error, Error.new(:s7, operation, reason, code: code)}
  end

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
