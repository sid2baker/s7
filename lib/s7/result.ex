defmodule S7.Result do
  @moduledoc """
  Result of one item in a multi-item operation.

  `:indeterminate` means a write may have reached the PLC but no valid response
  established its outcome. `:not_attempted` means no bytes for that item were
  sent after an earlier batch failed.
  """

  alias S7.{Address, Error}

  @enforce_keys [:address, :status]
  defstruct [:address, :status, :value, :error]

  @type status :: :ok | :error | :indeterminate | :not_attempted
  @type t :: %__MODULE__{
          address: Address.t(),
          status: status(),
          value: S7.Data.value() | binary() | nil,
          error: Error.t() | nil
        }
end
