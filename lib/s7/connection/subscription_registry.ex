defmodule S7.Connection.SubscriptionRegistry do
  @moduledoc false

  alias S7.Connection.Subscription

  defstruct limit: 16, entries: %{}, monitor_index: %{}

  @type t :: %__MODULE__{
          limit: pos_integer(),
          entries: %{optional(reference()) => Subscription.t()},
          monitor_index: %{optional(reference()) => reference()}
        }
end
