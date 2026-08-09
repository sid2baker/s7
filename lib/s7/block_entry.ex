defmodule S7.Block.Entry do
  @moduledoc "One entry from a classic list-blocks-of-type response."

  alias S7.Block

  @enforce_keys [:block, :flags, :language, :language_code, :raw]
  defstruct [:block, :flags, :language, :language_code, :raw]

  @type t :: %__MODULE__{
          block: Block.t(),
          flags: byte(),
          language: Block.language(),
          language_code: byte(),
          raw: binary()
        }
end
