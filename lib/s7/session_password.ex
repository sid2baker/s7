defmodule S7.SessionPassword do
  @moduledoc false

  alias S7.Error

  @enforce_keys [:value]
  defstruct [:value]

  @opaque t :: %__MODULE__{value: binary()}

  @doc false
  @spec new(term()) :: {:ok, t()} | {:error, Error.t()}
  def new(value) when is_binary(value) and byte_size(value) in 1..8 do
    if printable_ascii?(value) do
      {:ok, %__MODULE__{value: value}}
    else
      invalid()
    end
  end

  def new(_value), do: invalid()

  @doc false
  @spec padded(t()) :: binary()
  def padded(%__MODULE__{value: value}) do
    value <> :binary.copy(" ", 8 - byte_size(value))
  end

  @doc false
  @spec validate_and_pad(term()) :: {:ok, binary()} | {:error, Error.t()}
  def validate_and_pad(%__MODULE__{value: value}) do
    with {:ok, password} <- new(value) do
      {:ok, padded(password)}
    end
  end

  def validate_and_pad(_password), do: invalid()

  defp printable_ascii?(value),
    do: value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x20..0x7E))

  defp invalid,
    do: {:error, Error.new(:client, :authenticate, :invalid_session_password)}
end

defimpl Inspect, for: S7.SessionPassword do
  def inspect(_password, _opts), do: "#S7.SessionPassword<redacted>"
end
