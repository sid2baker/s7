defmodule S7.Connection.Controller do
  @moduledoc false

  alias S7.Connection.DestructiveRequest
  alias S7.Destructive
  alias S7.Protocol.PLCControl

  @spec execute(pid(), PLCControl.action(), Destructive.limits(), atom()) ::
          :ok | {:error, S7.Error.t()}
  def execute(connection, action, limits, operation) do
    with {:ok, request} <- PLCControl.request(action, operation) do
      DestructiveRequest.execute(
        connection,
        request,
        limits,
        operation,
        action,
        &PLCControl.decode_response(&1, action, operation)
      )
    end
  end
end
