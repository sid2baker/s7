defmodule S7.Protocol.Blocks.Transaction do
  @moduledoc false

  alias S7.Block

  @enforce_keys [:action, :max_bytes, :max_fragments]
  defstruct [
    :action,
    :type,
    :block,
    :max_bytes,
    :max_fragments,
    :data_unit_reference,
    fragment_count: 0,
    size: 0,
    parts: []
  ]

  @type action :: :counts | :list | :info
  @type t :: %__MODULE__{
          action: action(),
          type: Block.known_type() | nil,
          block: Block.t() | nil,
          max_bytes: pos_integer(),
          max_fragments: pos_integer(),
          data_unit_reference: byte() | nil,
          fragment_count: non_neg_integer(),
          size: non_neg_integer(),
          parts: [binary()]
        }
end
