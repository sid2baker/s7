defmodule S7 do
  @moduledoc """
  An S7comm client for classic Siemens S7 communication over ISO-on-TCP.

  The public API lives in `S7.Client`. Protocol and transport modules are pure
  binary codecs and can be used independently for diagnostics and testing.

  S7comm-plus, symbolic addressing, block operations, PLC control, alarms,
  diagnostics, and userdata services are outside the current scope.
  """
end
