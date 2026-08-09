defmodule S7 do
  @moduledoc """
  An S7comm client for classic Siemens S7 communication over ISO-on-TCP.

  The public API lives in `S7.Client`. Protocol and transport modules are pure
  binary codecs and can be used independently for diagnostics and testing.

  S7comm-plus, symbolic addressing, block download, PLC control, alarms, and
  programmer diagnostics are outside the current scope. The client supports
  bounded classic block upload and parsing in addition to bounded SZL reads,
  typed CPU metadata, block directory and information queries, PLC clock
  access, and protected-session authorization.
  """
end
