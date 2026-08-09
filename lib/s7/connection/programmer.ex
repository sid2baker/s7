defmodule S7.Connection.Programmer do
  @moduledoc false

  alias S7.{Connection, Error}
  alias S7.Connection.TransactionCleanup
  alias S7.Programmer, as: ProgrammerModel
  alias S7.Protocol.{Programmer, UserData}

  @spec validate_options(term(), atom()) ::
          {:ok, Programmer.limits()} | {:error, Error.t()}
  defdelegate validate_options(opts, operation), to: Programmer

  @spec diagnostic(
          pid(),
          ProgrammerModel.Event.service() | byte(),
          binary(),
          binary(),
          Programmer.limits(),
          atom()
        ) ::
          {:ok, ProgrammerModel.Event.t()} | {:error, Error.t()}
  def diagnostic(connection, service, parameters, data, limits, operation) do
    with {:ok, request, job} <-
           Programmer.start_request(service, parameters, data, operation) do
      execute(connection, request, job, limits, operation, &{:ok, &1})
    end
  end

  @spec variable_status(pid(), [S7.Address.t()], Programmer.limits()) ::
          {:ok, ProgrammerModel.VariableStatus.t()} | {:error, Error.t()}
  def variable_status(connection, addresses, limits) do
    with {:ok, request, job} <- Programmer.variable_status_request(addresses, :variable_status) do
      execute(connection, request, job, limits, :variable_status, fn event ->
        Programmer.decode_variable_status(event, addresses, :variable_status)
      end)
    end
  end

  defp execute(connection, request, job, limits, operation, decoder) do
    with {:ok, token} <-
           Connection.begin_transaction(connection, operation, transaction_options(limits)) do
      start_job(connection, token, request, job, limits, operation, decoder)
    end
  end

  defp start_job(connection, token, request, job, limits, operation, decoder) do
    with {:ok, response} <- transaction_userdata(connection, token, request),
         {:ok, job} <-
           Programmer.decode_start_response(
             response,
             request,
             job,
             response.header.pdu_reference,
             operation
           ) do
      run_job(connection, token, job, limits, operation, decoder)
    else
      {:error, %Error{} = error} -> finish_start_failure(connection, token, error)
    end
  end

  defp run_job(connection, token, job, limits, operation, decoder) do
    filter = %{
      function_group: :programmer,
      subfunction: job.subfunction,
      sequence: job.sequence,
      type: :indication
    }

    case Connection.subscribe_userdata(connection, filter, queue_limit: 1) do
      {:ok, subscription} ->
        execute_enabled_job(
          connection,
          token,
          subscription,
          job,
          limits,
          operation,
          decoder
        )

      {:error, %Error{} = error} ->
        cleanup_job(connection, token, nil, job, {:error, error}, operation)
    end
  end

  defp execute_enabled_job(connection, token, subscription, job, limits, operation, decoder) do
    result =
      with {:ok, request} <- Programmer.enable_request(job, operation),
           {:ok, response} <- transaction_userdata(connection, token, request),
           :ok <-
             Programmer.decode_management_response(
               response,
               request,
               response.header.pdu_reference,
               operation
             ),
           {:ok, indication} <-
             Connection.next_userdata(connection, subscription, limits.step_timeout),
           {:ok, event} <- Programmer.decode_indication(indication, job, operation) do
        decoder.(event)
      end

    cleanup_job(connection, token, subscription, job, result, operation)
  end

  defp cleanup_job(connection, token, subscription, job, result, operation) do
    with {:ok, request} <- Programmer.delete_request(job, operation),
         {:ok, response} <- transaction_userdata(connection, token, request),
         :ok <-
           Programmer.decode_management_response(
             response,
             request,
             response.header.pdu_reference,
             operation
           ),
         :ok <- unsubscribe(connection, subscription),
         :ok <- Connection.end_transaction(connection, token) do
      normalize_result(result, operation)
    else
      {:error, %Error{} = cleanup_error} ->
        abort_cleanup(connection, token, subscription, result, cleanup_error)
    end
  end

  defp finish_start_failure(connection, token, %Error{reason: reason} = error)
       when reason in [
              :access_denied,
              :address_out_of_range,
              :data_type_inconsistent,
              :data_type_not_supported,
              :hardware_fault,
              :invalid_userdata,
              :invalid_userdata_parameter,
              :invalid_userdata_payload,
              :object_not_found,
              :pdu_too_large,
              :plc_error,
              :userdata_error
            ] do
    TransactionCleanup.release(connection, token, error)
  end

  defp finish_start_failure(connection, token, error),
    do: TransactionCleanup.abort(connection, token, error)

  defp abort_cleanup(connection, token, subscription, result, cleanup_error) do
    _ = unsubscribe(connection, subscription)

    error =
      case result do
        {:error, %Error{} = original} ->
          %{original | details: Map.put(original.details, :cleanup, error_summary(cleanup_error))}

        {:ok, _value} ->
          %{
            cleanup_error
            | details: Map.put(cleanup_error.details, :outcome, :sample_received_cleanup_failed)
          }
      end

    TransactionCleanup.abort(connection, token, error)
  end

  defp transaction_userdata(connection, token, message) do
    with {:ok, pdu} <- UserData.to_pdu(message, 0) do
      Connection.transaction_request(connection, token, pdu)
    end
  end

  defp unsubscribe(_connection, nil), do: :ok

  defp unsubscribe(connection, subscription),
    do: Connection.unsubscribe_userdata(connection, subscription)

  defp error_summary(error),
    do: %{layer: error.layer, reason: error.reason, code: error.code}

  defp normalize_result({:error, %Error{} = error}, operation),
    do: {:error, %{error | operation: operation}}

  defp normalize_result(result, _operation), do: result

  defp transaction_options(limits) do
    [
      timeout: limits.timeout,
      step_timeout: limits.step_timeout,
      maximum_messages: 10,
      maximum_bytes: 1_048_576,
      inbox_limit: 1
    ]
  end
end
