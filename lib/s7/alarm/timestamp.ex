defmodule S7.Alarm.Timestamp do
  @moduledoc """
  Validated classic S7 alarm timestamp.

  Alarm timestamps use the eight-byte `DATE_AND_TIME` representation. They do
  not carry a timezone. `weekday` retains the Siemens weekday number (`1` for
  Sunday through `7` for Saturday), and `raw` retains the exact wire bytes.
  """

  @enforce_keys [:datetime, :weekday, :raw]
  defstruct [:datetime, :weekday, :raw]

  @type t :: %__MODULE__{
          datetime: NaiveDateTime.t(),
          weekday: 1..7,
          raw: <<_::64>>
        }
end
