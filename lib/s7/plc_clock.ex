defmodule S7.PLCClock do
  @moduledoc """
  A timezone-free value read from a classic PLC clock.

  Classic clock telegrams carry local civil time without a UTC offset. The
  century byte is retained as a hint because observed CPUs do not consistently
  encode it; `datetime` follows the validated two-digit Siemens year pivot.
  """

  @enforce_keys [:datetime, :reserved, :century_hint, :raw]
  defstruct [:datetime, :reserved, :century_hint, :raw]

  @type t :: %__MODULE__{
          datetime: NaiveDateTime.t(),
          reserved: byte(),
          century_hint: byte(),
          raw: binary()
        }
end
