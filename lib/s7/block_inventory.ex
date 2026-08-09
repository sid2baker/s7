defmodule S7.BlockInventory do
  @moduledoc """
  Counts reported by the classic block directory, keyed by block type.

  Unknown type codes remain keys of the form `{:unknown, code}`.
  """

  alias S7.Block

  @enforce_keys [:counts, :raw]
  defstruct [:counts, :raw]

  @type t :: %__MODULE__{
          counts: %{optional(Block.decoded_type()) => non_neg_integer()},
          raw: binary()
        }
end
