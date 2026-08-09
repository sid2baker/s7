defmodule S7.Session do
  @moduledoc """
  Authorization operations for one classic S7 session.

  Classic session passwords provide no encryption, integrity, or peer
  authentication and are never retained for reconnect.
  """

  alias S7.{API, Connection, Error, SessionPassword}

  @doc """
  Authenticates the current session with the PLC's configured password.
  """
  @spec authenticate(S7.t(), binary()) :: :ok | {:error, Error.t()}
  def authenticate(client, password) do
    with {:ok, password} <- SessionPassword.new(password) do
      API.call(fn -> Connection.authenticate(client, password) end, :authenticate)
    end
  end

  @doc """
  Clears authorization established for the current session.
  """
  @spec logout(S7.t()) :: :ok | {:error, Error.t()}
  def logout(client), do: API.call(fn -> Connection.logout(client) end, :logout)
end
