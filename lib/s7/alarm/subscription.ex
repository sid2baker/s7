defmodule S7.Alarm.Subscription do
  @moduledoc """
  Handle for one remote classic alarm-message subscription.

  The handle belongs to the process that created it and to the current S7
  session. Events are delivered to that process as
  `{:s7, subscription.reference, event}` messages. The handle becomes stale
  after unsubscribe, connection loss, or reconnect.
  """

  @enforce_keys [:connection, :reference, :alarm_type, :subscription_key]
  defstruct [:connection, :reference, :alarm_type, :subscription_key]

  @type alarm_type :: :alarm_s | :alarm_8
  @type connection ::
          pid() | atom() | {atom(), node()} | {:global, term()} | {:via, module(), term()}

  @type t :: %__MODULE__{
          connection: connection(),
          reference: reference(),
          alarm_type: alarm_type(),
          subscription_key: <<_::64>>
        }
end
