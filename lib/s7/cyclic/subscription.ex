defmodule S7.Cyclic.Subscription do
  @moduledoc """
  Handle for one remote classic cyclic-service job.

  A handle belongs to the process that created it and to the current S7
  session. Setup snapshots and subsequent updates are delivered to that
  process as `{:s7, subscription.reference, event}` messages.
  """

  alias S7.Address
  alias S7.Cyclic.Interval

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
    :addresses
  ]

  @type mode :: :cyclic | :change_driven
  @type connection ::
          pid() | atom() | {atom(), node()} | {:global, term()} | {:via, module(), term()}

  @type t :: %__MODULE__{
          connection: connection(),
          reference: reference(),
          job_id: byte(),
          mode: mode(),
          interval: Interval.t(),
          item_specs: [binary()],
          typed?: boolean(),
          addresses: [Address.t()] | nil
        }
end
