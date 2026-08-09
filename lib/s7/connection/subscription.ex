defmodule S7.Connection.Subscription do
  @moduledoc false

  alias S7.Protocol.UserData

  defstruct [
    :reference,
    :owner,
    :monitor,
    :filter,
    :waiter,
    :timer,
    :timer_token,
    :error,
    queue: {[], []},
    queued_count: 0,
    queue_limit: 64
  ]

  @type filter :: %{
          optional(:function_group) => UserData.Parameter.function_group() | :any,
          optional(:subfunction) => byte() | :any,
          optional(:sequence) => byte() | :any,
          optional(:type) => UserData.Parameter.function_type() | :any
        }

  @type t :: %__MODULE__{
          reference: reference(),
          owner: pid(),
          monitor: reference(),
          filter: filter(),
          waiter: :gen_statem.from() | nil,
          timer: reference() | nil,
          timer_token: reference() | nil,
          error: S7.Error.t() | nil,
          queue: :queue.queue(UserData.t()),
          queued_count: non_neg_integer(),
          queue_limit: pos_integer()
        }
end
