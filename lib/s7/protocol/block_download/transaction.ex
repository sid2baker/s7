defmodule S7.Protocol.BlockDownload.Transaction do
  @moduledoc false

  alias S7.Block

  @enforce_keys [:block, :image, :mc7_size, :operation]
  defstruct [
    :block,
    :image,
    :mc7_size,
    :operation,
    stage: :request_download,
    offset: 0,
    fragment_count: 0,
    references: MapSet.new()
  ]

  @type stage :: :request_download | :download | :download_ended | :complete
  @type t :: %__MODULE__{
          block: Block.t(),
          image: binary(),
          mc7_size: non_neg_integer(),
          operation: atom(),
          stage: stage(),
          offset: non_neg_integer(),
          fragment_count: non_neg_integer(),
          references: MapSet.t(0..0xFFFF)
        }
end
