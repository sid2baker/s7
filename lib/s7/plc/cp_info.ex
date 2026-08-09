defmodule S7.PLC.CPInfo do
  @moduledoc "Communication-processor limits decoded from SZL `0x0131`, index `1`."

  @enforce_keys [:max_pdu_length, :max_connections, :max_mpi_rate, :max_bus_rate, :record]
  defstruct [:max_pdu_length, :max_connections, :max_mpi_rate, :max_bus_rate, :record]

  @type t :: %__MODULE__{
          max_pdu_length: 0..0xFFFF,
          max_connections: 0..0xFFFF,
          max_mpi_rate: 0..0xFFFFFFFF,
          max_bus_rate: 0..0xFFFFFFFF,
          record: binary()
        }
end
