defmodule S7.OrderCode do
  @moduledoc """
  Module order code and three-part firmware/hardware version from SZL `0x0011`.
  """

  @enforce_keys [:code, :version, :record]
  defstruct [:code, :version, :record]

  @type t :: %__MODULE__{
          code: String.t(),
          version: {byte(), byte(), byte()},
          record: binary()
        }
end
