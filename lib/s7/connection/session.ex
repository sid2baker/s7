defmodule S7.Connection.Session do
  @moduledoc false

  defstruct local_reference: nil,
            remote_reference: nil,
            authenticated: false
end
