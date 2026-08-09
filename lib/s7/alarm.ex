defmodule S7.Alarm.Event do
  @moduledoc """
  One unsolicited classic S7comm alarm or notification indication.

  Events and their nested records preserve exact wire bytes. The connection
  delivers every accepted indication in receive order and does not deduplicate
  repeated event IDs or state transitions.
  """

  alias S7.Alarm.Timestamp

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
          timestamp: Timestamp.t(),
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

defmodule S7.Alarm.Acknowledgement do
  @moduledoc """
  Explicit classic alarm acknowledgment request item.

  `ack_state_going` and `ack_state_coming` are the signal masks copied from the
  alarm object being acknowledged. Applications can use an alarm event object
  directly through `S7.Client.acknowledge_alarm/3` instead of constructing this
  struct.
  """

  @enforce_keys [:event_id, :ack_state_going, :ack_state_coming]
  defstruct [:event_id, :ack_state_going, :ack_state_coming]

  @type t :: %__MODULE__{
          event_id: non_neg_integer(),
          ack_state_going: byte(),
          ack_state_coming: byte()
        }

  defmodule Result do
    @moduledoc "PLC result for one transmitted alarm acknowledgment."

    alias S7.Error

    @enforce_keys [:acknowledgement, :return_code, :status]
    defstruct [:acknowledgement, :return_code, :status, :error]

    @type t :: %__MODULE__{
            acknowledgement: S7.Alarm.Acknowledgement.t(),
            return_code: byte(),
            status: :ok | :error,
            error: Error.t() | nil
          }
  end
end

defmodule S7.Alarm.Query do
  @moduledoc """
  Raw-first result of one classic alarm query.

  Query record headers are decoded where the captured format is unambiguous.
  CPU-family-specific record tails remain in `details` and every record retains
  its complete `raw` representation.
  """

  @enforce_keys [
    :selector,
    :function_id,
    :reported_count,
    :return_code,
    :transport_size,
    :complete_length,
    :records,
    :raw
  ]
  defstruct [
    :selector,
    :function_id,
    :reported_count,
    :return_code,
    :transport_size,
    :complete_length,
    :records,
    :raw
  ]

  @type selector :: {:alarm_type, :alarm_s | :alarm_8} | {:event_id, non_neg_integer()}
  @type t :: %__MODULE__{
          selector: selector(),
          function_id: byte(),
          reported_count: byte(),
          return_code: byte(),
          transport_size: byte(),
          complete_length: non_neg_integer(),
          records: [__MODULE__.Record.t()],
          raw: binary()
        }

  defmodule Record do
    @moduledoc "One bounded alarm-query dataset."

    @enforce_keys [
      :dataset_length,
      :reserved,
      :alarm_type,
      :event_id,
      :reserved_state,
      :event_state,
      :ack_state_going,
      :ack_state_coming,
      :details,
      :raw
    ]
    defstruct [
      :dataset_length,
      :reserved,
      :alarm_type,
      :event_id,
      :reserved_state,
      :event_state,
      :ack_state_going,
      :ack_state_coming,
      :details,
      :raw
    ]

    @type t :: %__MODULE__{
            dataset_length: byte(),
            reserved: non_neg_integer(),
            alarm_type: :scan | :alarm_8 | :alarm_s | byte(),
            event_id: non_neg_integer(),
            reserved_state: byte(),
            event_state: byte(),
            ack_state_going: byte(),
            ack_state_coming: byte(),
            details: binary(),
            raw: binary()
          }
  end
end

defmodule S7.Alarm.Subscription do
  @moduledoc """
  Handle for one remote classic alarm-message subscription.

  The handle belongs to the process that created it and to the current S7
  session. It becomes stale after unsubscribe, connection loss, or reconnect.
  """

  @enforce_keys [:connection, :reference, :alarm_type, :subscription_key]
  defstruct [:connection, :reference, :alarm_type, :subscription_key]

  @type alarm_type :: :alarm_s | :alarm_8
  @type t :: %__MODULE__{
          connection: pid(),
          reference: reference(),
          alarm_type: alarm_type(),
          subscription_key: <<_::64>>
        }
end

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
