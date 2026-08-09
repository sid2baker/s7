defmodule S7.Cyclic.Event do
  @moduledoc """
  One initial snapshot or unsolicited classic cyclic-service update.

  Items retain their complete wire records. Typed cyclic subscriptions also
  expose decoded values; raw and change-driven subscriptions leave `value`
  unset because their records may use CPU-specific query layouts.
  """

  @enforce_keys [:job_id, :subfunction, :items, :raw]
  defstruct [:job_id, :subfunction, :items, :raw]

  @type t :: %__MODULE__{
          job_id: byte(),
          subfunction: byte(),
          items: [__MODULE__.Item.t()],
          raw: binary()
        }

  defmodule Item do
    @moduledoc """
    One cyclic-service item and its original wire representation.
    """

    alias S7.{Address, Error}
    alias S7.Protocol.DataItem

    @enforce_keys [
      :return_code,
      :transport_size,
      :encoded_length,
      :data,
      :padding,
      :raw
    ]
    defstruct [
      :address,
      :return_code,
      :transport_size,
      :encoded_length,
      :data,
      :padding,
      :value,
      :error,
      :raw
    ]

    @type t :: %__MODULE__{
            address: Address.t() | nil,
            return_code: byte(),
            transport_size: DataItem.transport_size() | byte(),
            encoded_length: non_neg_integer(),
            data: binary(),
            padding: binary(),
            value: S7.Data.value() | nil,
            error: Error.t() | nil,
            raw: binary()
          }
  end
end

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
