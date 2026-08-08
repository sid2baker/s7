defmodule S7.Error do
  @moduledoc """
  Structured error returned by the public S7 API.

  `code` retains a raw protocol or system code when one exists. `details`
  carries diagnostic context and must not be required for control flow.
  """

  defexception [:layer, :operation, :code, :reason, details: %{}]

  @type layer :: :address | :data | :tcp | :tpkt | :cotp | :s7 | :client
  @type t :: %__MODULE__{
          layer: layer(),
          operation: atom(),
          code: term() | nil,
          reason: atom(),
          details: map()
        }

  @doc false
  @spec new(layer(), atom(), atom(), keyword()) :: t()
  def new(layer, operation, reason, opts \\ []) do
    %__MODULE__{
      layer: layer,
      operation: operation,
      reason: reason,
      code: Keyword.get(opts, :code),
      details: Keyword.get(opts, :details, %{})
    }
  end

  @impl Exception
  def message(%__MODULE__{} = error) do
    base = "#{error.operation} failed at #{error.layer}: #{error.reason}"

    case error.code do
      nil -> base
      code -> base <> " (code: #{inspect(code)})"
    end
  end
end
