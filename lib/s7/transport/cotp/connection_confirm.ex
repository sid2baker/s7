defmodule S7.Transport.COTP.ConnectionConfirm do
  @moduledoc """
  A COTP Connection Confirm TPDU.

  COTP parameters are optional in confirmations, so TSAP and TPDU-size fields
  may be `nil` after decoding.
  """

  defstruct [
    :src_tsap,
    :dst_tsap,
    :tpdu_size,
    destination_reference: 0,
    source_reference: 0,
    class_option: 0,
    unknown_parameters: []
  ]

  @type t :: %__MODULE__{
          src_tsap: binary() | nil,
          dst_tsap: binary() | nil,
          tpdu_size: pos_integer() | nil,
          destination_reference: 0..0xFFFF,
          source_reference: 0..0xFFFF,
          class_option: byte(),
          unknown_parameters: [{byte(), binary()}]
        }
end
