defmodule S7.AlarmEvent do
  @moduledoc """
  One unsolicited classic S7comm alarm or notification indication.

  Events and their nested records preserve exact wire bytes. The connection
  delivers every accepted indication in receive order and does not deduplicate
  repeated event IDs or state transitions.
  """

  alias S7.AlarmTimestamp

  @enforce_keys [:subfunction, :kind, :timestamp, :function_id, :objects, :raw]
  defstruct [:subfunction, :kind, :timestamp, :function_id, :objects, :raw]

  @type kind ::
          :alarm_8
          | :notify
          | :acknowledgement
          | :alarm_sq
          | :alarm_s
          | :alarm_sc
          | :notify_8

  @type t :: %__MODULE__{
          subfunction: byte(),
          kind: kind(),
          timestamp: AlarmTimestamp.t(),
          function_id: byte(),
          objects: [__MODULE__.Object.t()],
          raw: binary()
        }

  defmodule Object do
    @moduledoc """
    One alarm message object.

    Signal states are retained as eight-bit masks. `specification_raw` contains
    the bounded variable specification; `raw` also includes associated-value
    records belonging to this object.
    """

    @enforce_keys [
      :length,
      :syntax_id,
      :associated_value_count,
      :event_id,
      :ack_state_going,
      :ack_state_coming,
      :associated_values,
      :specification_raw,
      :raw
    ]
    defstruct [
      :length,
      :syntax_id,
      :associated_value_count,
      :event_id,
      :event_state,
      :local_state,
      :ack_state_going,
      :ack_state_coming,
      :event_state_going,
      :event_state_coming,
      :event_state_last_changed,
      :reserved_state,
      :fixed_extra,
      :associated_values,
      :specification_raw,
      :raw
    ]

    @type t :: %__MODULE__{
            length: byte(),
            syntax_id: byte(),
            associated_value_count: byte(),
            event_id: non_neg_integer(),
            event_state: byte() | nil,
            local_state: byte() | nil,
            ack_state_going: byte() | nil,
            ack_state_coming: byte() | nil,
            event_state_going: byte() | nil,
            event_state_coming: byte() | nil,
            event_state_last_changed: byte() | nil,
            reserved_state: byte() | nil,
            fixed_extra: binary() | nil,
            associated_values: [__MODULE__.AssociatedValue.t()],
            specification_raw: binary(),
            raw: binary()
          }
  end

  defmodule Object.AssociatedValue do
    @moduledoc """
    One raw alarm associated-value record.

    Transport metadata is retained without assigning a PLC application type.
    A non-success PLC return code is exposed through `error` while its original
    bytes remain available.
    """

    alias S7.Error

    @enforce_keys [:return_code, :transport_size, :encoded_length, :data, :raw]
    defstruct [:return_code, :transport_size, :encoded_length, :data, :error, :raw]

    @type t :: %__MODULE__{
            return_code: byte(),
            transport_size: byte(),
            encoded_length: non_neg_integer(),
            data: binary(),
            error: Error.t() | nil,
            raw: binary()
          }
  end
end
