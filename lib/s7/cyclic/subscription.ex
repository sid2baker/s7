defmodule S7.Cyclic.Subscription do
  @moduledoc """
  Handle for one remote classic cyclic-service job.

  A handle belongs to the process that created it and to the current S7
  session. `initial` contains the optional snapshot bundled with the setup or
  most recent change-driven modification response.
  """

  alias S7.Address
  alias S7.Cyclic.{Event, Interval}

  @enforce_keys [
    :connection,
    :reference,
    :job_id,
    :mode,
    :interval,
    :item_specs,
    :typed?
  ]
  defstruct [
    :connection,
    :reference,
    :job_id,
    :mode,
    :interval,
    :item_specs,
    :typed?,
    :addresses,
    :initial
  ]

  @type mode :: :cyclic | :change_driven
  @type t :: %__MODULE__{
          connection: pid(),
          reference: reference(),
          job_id: byte(),
          mode: mode(),
          interval: Interval.t(),
          item_specs: [binary()],
          typed?: boolean(),
          addresses: [Address.t()] | nil,
          initial: Event.t() | nil
        }
end
