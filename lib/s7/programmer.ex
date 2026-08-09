defmodule S7.Programmer do
  @moduledoc """
  Bounded, read-only classic programmer services.
  """

  alias S7.{API, Error}
  alias S7.Connection.Programmer, as: Runtime

  @doc """
  Samples one capture-backed raw programmer diagnostic job.

  The job is set up, enabled once, deleted, and released before this function
  returns. Options are `:timeout` and `:step_timeout`.
  """
  @spec diagnostic_raw(
          S7.t(),
          S7.Programmer.Event.service() | byte(),
          binary(),
          binary(),
          keyword()
        ) :: {:ok, S7.Programmer.Event.t()} | {:error, Error.t()}
  def diagnostic_raw(client, service, setup_parameters, setup_data, opts \\ []) do
    operation = :programmer_diagnostic

    with {:ok, limits} <- Runtime.validate_options(opts, operation) do
      API.call(
        fn ->
          Runtime.diagnostic(client, service, setup_parameters, setup_data, limits, operation)
        end,
        operation
      )
    end
  end

  @doc """
  Samples addresses through the classic STEP 7 variable-status service.
  """
  @spec variable_status(S7.t(), [S7.address()], keyword()) ::
          {:ok, S7.Programmer.VariableStatus.t()} | {:error, Error.t()}
  def variable_status(client, addresses, opts \\ []) do
    with {:ok, addresses} <- API.addresses(addresses, :variable_status),
         {:ok, limits} <- Runtime.validate_options(opts, :variable_status) do
      API.call(fn -> Runtime.variable_status(client, addresses, limits) end, :variable_status)
    end
  end
end
