defmodule S7.Transport.COTP.Data do
  @moduledoc """
  A COTP Data TPDU.
  """

  @enforce_keys [:payload]
  defstruct [:payload, eot: true, tpdu_number: 0]

  @type t :: %__MODULE__{
          payload: binary(),
          eot: boolean(),
          tpdu_number: 0..0x7F
        }
end
