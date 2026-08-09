defmodule S7.Connection.Close do
  @moduledoc false

  defstruct [:from, :timer, :token]

  @type t :: %__MODULE__{
          from: :gen_statem.from() | nil,
          timer: reference() | nil,
          token: reference() | nil
        }
end
