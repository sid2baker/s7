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
