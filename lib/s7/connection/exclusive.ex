defmodule S7.Connection.Exclusive do
  @moduledoc false

  defstruct [
    :token,
    :owner,
    :monitor,
    :from,
    :operation,
    :timer,
    :timer_token,
    :receive_from,
    :receive_timer,
    :receive_token,
    step_timeout: 5_000,
    maximum_messages: 1_024,
    maximum_bytes: 1_048_576,
    inbox_limit: 64,
    message_count: 0,
    byte_count: 0,
    inbox: {[], []},
    inbox_count: 0
  ]

  @type t :: %__MODULE__{
          token: reference(),
          owner: pid(),
          monitor: reference(),
          from: :gen_statem.from() | nil,
          operation: atom(),
          timer: reference() | nil,
          timer_token: reference() | nil,
          receive_from: :gen_statem.from() | nil,
          receive_timer: reference() | nil,
          receive_token: reference() | nil,
          step_timeout: pos_integer(),
          maximum_messages: pos_integer(),
          maximum_bytes: pos_integer(),
          inbox_limit: pos_integer(),
          message_count: non_neg_integer(),
          byte_count: non_neg_integer(),
          inbox: :queue.queue(S7.Protocol.PDU.t()),
          inbox_count: non_neg_integer()
        }
end
