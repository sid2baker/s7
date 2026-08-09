defmodule S7.Connection.Reconnect do
  @moduledoc false

  @enforce_keys [:enabled, :min_delay, :max_delay, :max_attempts, :jitter, :delay]
  defstruct [
    :enabled,
    :min_delay,
    :max_delay,
    :max_attempts,
    :jitter,
    :delay,
    :timer,
    :token,
    attempts: 0
  ]

  @type t :: %__MODULE__{
          enabled: boolean(),
          min_delay: pos_integer(),
          max_delay: pos_integer(),
          max_attempts: pos_integer() | :infinity,
          jitter: float(),
          delay: pos_integer(),
          timer: reference() | nil,
          token: reference() | nil,
          attempts: non_neg_integer()
        }
end
