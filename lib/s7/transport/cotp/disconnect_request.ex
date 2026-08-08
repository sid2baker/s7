defmodule S7.Transport.COTP.DisconnectRequest do
  @moduledoc """
  A COTP Disconnect Request TPDU.

  The `reason` field contains the protocol reason octet. Additional
  information is represented separately from unrecognised TLV parameters so
  captures can be decoded and encoded without losing diagnostic data.
  """

  defstruct destination_reference: 0,
            source_reference: 0,
            reason: 0,
            additional_information: nil,
            unknown_parameters: []

  @type t :: %__MODULE__{
          destination_reference: 0..0xFFFF,
          source_reference: 0..0xFFFF,
          reason: byte(),
          additional_information: binary() | nil,
          unknown_parameters: [{byte(), binary()}]
        }
end
