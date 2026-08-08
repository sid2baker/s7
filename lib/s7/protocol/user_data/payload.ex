defmodule S7.Protocol.UserData.Payload do
  @moduledoc """
  The common four-byte payload header and opaque userdata service bytes.
  """

  @enforce_keys [:data]
  defstruct return_code: 0xFF, transport_size: 0x09, data: <<>>

  @type t :: %__MODULE__{
          return_code: byte(),
          transport_size: byte(),
          data: binary()
        }
end
