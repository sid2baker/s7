defmodule S7.ProgrammerEvent do
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
