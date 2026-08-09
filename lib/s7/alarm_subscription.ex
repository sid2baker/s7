defmodule S7.AlarmSubscription do
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
