defmodule S7.PLC.Status do
  @moduledoc """
  Raw and normalized PLC operating status decoded from SZL `0x0424`.
  """

  @enforce_keys [:state, :code, :record]
  defstruct [:state, :code, :record]

  @type state :: :run | :stop | :unknown
  @type t :: %__MODULE__{state: state(), code: byte(), record: binary()}
end
