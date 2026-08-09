defmodule S7.Programmer.VariableStatus do
  @moduledoc """
  One completed classic programmer variable-status sample.

  The raw indication records are retained alongside best-effort typed values.
  A successful outer result only means the job exchange was valid; inspect each
  item's `error` field for PLC item failures.
  """

  @enforce_keys [:sequence, :parameters, :items, :raw]
  defstruct [:sequence, :parameters, :items, :raw]

  @type t :: %__MODULE__{
          sequence: byte(),
          parameters: binary(),
          items: [__MODULE__.Item.t()],
          raw: binary()
        }

  defmodule Item do
    @moduledoc "One variable-status result with its original wire representation."

    alias S7.{Address, Error}

    @enforce_keys [
      :address,
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

    @type t :: %__MODULE__{
            address: Address.t(),
            return_code: byte(),
            transport_size: byte(),
            encoded_length: non_neg_integer(),
            data: binary(),
            padding: binary(),
            value: S7.Data.value() | nil,
            error: Error.t() | nil,
            raw: binary()
          }
  end
end
