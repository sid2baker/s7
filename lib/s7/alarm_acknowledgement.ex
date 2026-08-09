defmodule S7.AlarmAcknowledgement do
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
    @moduledoc """
    PLC result for one transmitted alarm acknowledgment.
    """

    alias S7.Error

    @enforce_keys [:acknowledgement, :return_code, :status]
    defstruct [:acknowledgement, :return_code, :status, :error]

    @type t :: %__MODULE__{
            acknowledgement: S7.AlarmAcknowledgement.t(),
            return_code: byte(),
            status: :ok | :error,
            error: Error.t() | nil
          }
  end
end
