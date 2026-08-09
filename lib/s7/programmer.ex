defmodule S7.Programmer.Event do
  @moduledoc """
  One raw indication emitted by a classic programmer job.

  Programmer-service layouts vary by CPU and STEP 7 generation. The service
  envelope is decoded, while its parameter and data records remain available
  byte-for-byte for variants that are not yet understood.
  """

  @enforce_keys [:service, :subfunction, :sequence, :parameters, :data, :raw]
  defstruct [:service, :subfunction, :sequence, :parameters, :data, :raw]

  @type service ::
          :block_status
          | :variable_status
          | :output_istack
          | :output_bstack
          | :output_lstack
          | :read_job_list
          | :read_job
          | :block_status_v2

  @type t :: %__MODULE__{
          service: service(),
          subfunction: byte(),
          sequence: byte(),
          parameters: binary(),
          data: binary(),
          raw: binary()
        }
end

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
