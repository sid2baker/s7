defmodule S7.PLC.Status do
  @moduledoc """
  Raw and normalized PLC operating status decoded from SZL `0x0424`.
  """

  @enforce_keys [:state, :code, :record]
  defstruct [:state, :code, :record]

  @type state :: :run | :stop | :unknown
  @type t :: %__MODULE__{state: state(), code: byte(), record: binary()}
end

defmodule S7.PLC.Clock do
  @moduledoc """
  A timezone-free value read from a classic PLC clock.

  Classic clock telegrams carry local civil time without a UTC offset. The
  century byte is retained as a hint because observed CPUs do not consistently
  encode it; `datetime` follows the validated two-digit Siemens year pivot.
  """

  @enforce_keys [:datetime, :reserved, :century_hint, :raw]
  defstruct [:datetime, :reserved, :century_hint, :raw]

  @type t :: %__MODULE__{
          datetime: NaiveDateTime.t(),
          reserved: byte(),
          century_hint: byte(),
          raw: binary()
        }
end

defmodule S7.PLC.CPUInfo do
  @moduledoc """
  Component-identification strings decoded from SZL `0x001C`.

  The raw `components` map retains full 16-bit record indexes, including the
  rack and master/reserve flags returned by H systems.
  """

  defstruct [
    :module_type_name,
    :serial_number,
    :automation_system_name,
    :copyright,
    :module_name,
    components: %{}
  ]

  @type t :: %__MODULE__{
          module_type_name: String.t() | nil,
          serial_number: String.t() | nil,
          automation_system_name: String.t() | nil,
          copyright: String.t() | nil,
          module_name: String.t() | nil,
          components: %{optional(0..0xFFFF) => binary()}
        }
end

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

defmodule S7.PLC.OrderCode do
  @moduledoc "Module order code and three-part firmware/hardware version from SZL `0x0011`."

  @enforce_keys [:code, :version, :record]
  defstruct [:code, :version, :record]

  @type t :: %__MODULE__{
          code: String.t(),
          version: {byte(), byte(), byte()},
          record: binary()
        }
end
