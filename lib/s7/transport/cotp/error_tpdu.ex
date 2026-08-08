defmodule S7.Transport.COTP.ErrorTPDU do
  @moduledoc """
  A COTP Error TPDU.

  `invalid_tpdu` contains the optional invalid-TPDU parameter from the peer.
  """

  defstruct destination_reference: 0,
            reject_cause: 0,
            invalid_tpdu: nil,
            unknown_parameters: []

  @type t :: %__MODULE__{
          destination_reference: 0..0xFFFF,
          reject_cause: byte(),
          invalid_tpdu: binary() | nil,
          unknown_parameters: [{byte(), binary()}]
        }
end
