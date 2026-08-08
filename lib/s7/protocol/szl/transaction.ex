defmodule S7.Protocol.SZL.Transaction do
  @moduledoc false

  @enforce_keys [:id, :index, :max_bytes, :max_fragments]
  defstruct [
    :id,
    :index,
    :max_bytes,
    :max_fragments,
    :data_unit_reference,
    fragment_count: 0,
    size: 0,
    parts: []
  ]

  @type t :: %__MODULE__{
          id: 0..0xFFFF,
          index: 0..0xFFFF,
          max_bytes: pos_integer(),
          max_fragments: pos_integer(),
          data_unit_reference: byte() | nil,
          fragment_count: non_neg_integer(),
          size: non_neg_integer(),
          parts: [binary()]
        }
end
