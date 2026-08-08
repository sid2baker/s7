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
    batches: [],
    results: [],
    cancelled: false
  ]

  @type kind :: :read | :read_multi | :write | :write_multi

  @type t :: %__MODULE__{
          id: reference(),
          from: :gen_statem.from() | nil,
          monitor: reference() | nil,
          kind: kind(),
          operation: :read | :read_multi | :write | :write_multi,
          raw?: boolean() | nil,
          reference: 0..0xFFFF | nil,
          timer: reference() | nil,
          timer_token: reference() | nil,
          current_batch: list() | nil,
          enqueued_at: integer() | nil,
          started_at: integer() | nil,
          request_size: non_neg_integer() | nil,
          batches: [list()],
          results: [Result.t()],
          cancelled: boolean()
        }
end
