defmodule S7.Transport.COTP.ConnectionRequest do
  @moduledoc """
  A COTP Connection Request TPDU.
  """

  @enforce_keys [:src_tsap, :dst_tsap, :tpdu_size]
  defstruct [
    :src_tsap,
    :dst_tsap,
    :tpdu_size,
    destination_reference: 0,
    source_reference: 1,
    class_option: 0,
    unknown_parameters: []
  ]

  @type t :: %__MODULE__{
          src_tsap: binary(),
          dst_tsap: binary(),
          tpdu_size: pos_integer(),
          destination_reference: 0..0xFFFF,
          source_reference: 0..0xFFFF,
          class_option: byte(),
          unknown_parameters: [{byte(), binary()}]
        }
end
