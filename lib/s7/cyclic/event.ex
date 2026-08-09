defmodule S7.Cyclic.Event do
  @moduledoc """
  One initial snapshot or unsolicited classic cyclic-service update.

  Items retain their complete wire records. Typed cyclic subscriptions also
  expose decoded values; raw and change-driven subscriptions leave `value`
  unset because their records may use CPU-specific query layouts.
  """

  @enforce_keys [:job_id, :subfunction, :items, :raw]
  defstruct [:job_id, :subfunction, :items, :raw]

  @type t :: %__MODULE__{
          job_id: byte(),
          subfunction: byte(),
          items: [__MODULE__.Item.t()],
          raw: binary()
        }

  defmodule Item do
    @moduledoc """
    One cyclic-service item and its original wire representation.
    """

    alias S7.{Address, Error}

    @enforce_keys [
      :return_code,
      :transport_size,
      :encoded_length,
      :data,
      :padding,
      :raw
    ]
    defstruct [
      :address,
      :return_code,
      :transport_size,
      :encoded_length,
      :data,
      :padding,
      :value,
      :error,
      :raw
    ]

    @type transport_size :: :none | :bit | :byte | :integer | :dinteger | :real | :octet | byte()

    @type t :: %__MODULE__{
            address: Address.t() | nil,
            return_code: byte(),
            transport_size: transport_size(),
            encoded_length: non_neg_integer(),
            data: binary(),
            padding: binary(),
            value: S7.Data.value() | nil,
            error: Error.t() | nil,
            raw: binary()
          }
  end
end
