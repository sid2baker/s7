defmodule S7.Transport.COTP.DisconnectConfirm do
  @moduledoc """
  A COTP Disconnect Confirm TPDU.
  """

  defstruct destination_reference: 0,
            source_reference: 0,
            unknown_parameters: []

  @type t :: %__MODULE__{
          destination_reference: 0..0xFFFF,
          source_reference: 0..0xFFFF,
          unknown_parameters: [{byte(), binary()}]
        }
end
