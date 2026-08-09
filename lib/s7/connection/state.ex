defmodule S7.Connection.Request do
  @moduledoc false

  alias S7.Result

  @enforce_keys [:id, :from, :monitor, :kind, :operation, :batches]
  defstruct [
    :id,
    :from,
    :monitor,
    :kind,
    :operation,
    :raw?,
    :reference,
    :timer,
    :timer_token,
    :current_batch,
    :enqueued_at,
    :started_at,
    :request_size,
    :context,
    batches: [],
    results: [],
    cancelled: false
  ]

  @type kind ::
          :read
          | :read_multi
          | :write
          | :write_multi
          | :userdata
          | :szl
          | :blocks
          | :clock
          | :security
          | :transaction

  @type t :: %__MODULE__{
          id: reference(),
          from: :gen_statem.from() | nil,
          monitor: reference() | nil,
          kind: kind(),
          operation: atom(),
          raw?: boolean() | nil,
          reference: 0..0xFFFF | nil,
          timer: reference() | nil,
          timer_token: reference() | nil,
          current_batch: list() | nil,
          enqueued_at: integer() | nil,
          started_at: integer() | nil,
          request_size: non_neg_integer() | nil,
          context: term(),
          batches: [list()],
          results: [Result.t()],
          cancelled: boolean()
        }
end

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
    queue_limit: 64,
    session_bound: false,
    owner_down_operation: :userdata_subscription
  ]

  @type filter :: %{
          optional(:function_group) => UserData.Parameter.function_group() | :any,
          optional(:subfunction) => byte() | {:one_of, [byte()]} | :any,
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
          queue_limit: pos_integer(),
          session_bound: boolean(),
          owner_down_operation: atom()
        }
end
