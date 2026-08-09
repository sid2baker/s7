defmodule S7 do
  @moduledoc """
  An S7comm client for classic Siemens S7 communication over ISO-on-TCP.

  The public API lives in `S7.Client`. Protocol and transport modules are pure
  binary codecs and can be used independently for diagnostics and testing.

  S7comm-plus, symbolic addressing, alarms, and destructive programmer
  commands are outside the current scope. The client supports bounded classic
  block transfer, opt-in destructive block management and CPU control, bounded
  SZL reads, typed CPU metadata, block directory and information queries, PLC
  clock access, protected-session authorization, and raw-first read-only
  programmer diagnostics.
  """
end
