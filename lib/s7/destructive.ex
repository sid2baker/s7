defmodule S7.Destructive do
  @moduledoc false

  alias S7.{Error, Options}

  @default_timeout 30_000
  @default_step_timeout 5_000
  @maximum_timeout 3_600_000

  @type limits :: %{timeout: pos_integer(), step_timeout: pos_integer()}

  @spec validate_options(term(), atom(), atom()) ::
          {:ok, limits()} | {:error, Error.t()}
  def validate_options(opts, confirmation, operation) when is_list(opts) do
    allowed = [:confirm, :timeout, :step_timeout]

    with :ok <- Options.validate_keys(opts, allowed, operation),
         :ok <- validate_confirmation(opts, confirmation, operation),
         {:ok, timeout} <-
           Options.positive(opts, :timeout, @default_timeout, @maximum_timeout, operation),
         {:ok, step_timeout} <-
           Options.positive(
             opts,
             :step_timeout,
             @default_step_timeout,
             @maximum_timeout,
             operation
           ) do
      {:ok, %{timeout: timeout, step_timeout: step_timeout}}
    end
  end

  def validate_options(opts, _confirmation, operation),
    do: {:error, Error.new(:client, operation, :invalid_options, details: %{options: opts})}

  @spec authorize(map(), atom()) :: :ok | {:error, Error.t()}
  def authorize(%{destructive_operations: true}, _operation), do: :ok

  def authorize(_info, operation) do
    {:error,
     Error.new(:client, operation, :destructive_operations_disabled,
       details: %{required_connection_option: {:allow_destructive, true}}
     )}
  end

  defp validate_confirmation(opts, confirmation, operation) do
    if Keyword.get(opts, :confirm) == confirmation do
      :ok
    else
      {:error,
       Error.new(:client, operation, :destructive_confirmation_required,
         details: %{expected: confirmation, received: Keyword.get(opts, :confirm)}
       )}
    end
  end
end
