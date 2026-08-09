defmodule S7.Protocol.BlockUpload.Transaction do
  @moduledoc false

  alias S7.Block

  @enforce_keys [:block, :operation, :max_bytes, :max_fragments]
  defstruct [
    :block,
    :operation,
    :upload_id,
    :advertised_size,
    :max_bytes,
    :max_fragments,
    fragment_count: 0,
    size: 0,
    parts: []
  ]

  @type t :: %__MODULE__{
          block: Block.t(),
          operation: atom(),
          upload_id: 0..0xFFFFFFFF | nil,
          advertised_size: pos_integer() | nil,
          max_bytes: pos_integer(),
          max_fragments: pos_integer(),
          fragment_count: non_neg_integer(),
          size: non_neg_integer(),
          parts: [binary()]
        }
end
