defmodule S7.Cyclic.Interval do
  @moduledoc """
  The exact interval negotiated for one classic cyclic subscription.

  Classic S7comm represents an interval as an eight-bit factor multiplied by
  one of three bases. `milliseconds` is the exact effective interval; the
  client does not silently round a requested duration.
  """

  @enforce_keys [:base, :factor, :milliseconds]
  defstruct [:base, :factor, :milliseconds]

  @type base :: :hundred_milliseconds | :second | :ten_seconds
  @type t :: %__MODULE__{
          base: base(),
          factor: 1..0xFF,
          milliseconds: 100..2_550_000
        }
end
