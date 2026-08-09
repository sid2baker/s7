defmodule S7.Connection.Alarm do
  @moduledoc false

  alias S7.{
    AlarmAcknowledgement,
    AlarmEvent,
    AlarmQuery,
    AlarmSubscription,
    Connection,
    Error
  }

  alias S7.Connection.{Service, TransactionCleanup}
  alias S7.Protocol.{Alarm, UserData}

  @default_timeout 5_000
  @default_queue_limit 64

  @type subscription_options :: %{
          subscription_key: <<_::64>>,
          queue_limit: pos_integer(),
          timeout: pos_integer(),
          step_timeout: pos_integer()
        }

  @type request_options :: %{
          timeout: pos_integer(),
          step_timeout: pos_integer()
        }

  @spec validate_subscription_options(term(), atom()) ::
          {:ok, subscription_options()} | {:error, Error.t()}
  def validate_subscription_options(opts, operation) do
    with :ok <-
           Service.validate_options(
             opts,
             [:subscription_key, :queue_limit, :timeout, :step_timeout],
             operation
           ),
         {:ok, subscription_key} <- subscription_key_option(opts, operation),
         {:ok, queue_limit} <-
           Service.positive_option(opts, :queue_limit, @default_queue_limit, operation),
         {:ok, timeout} <- Service.positive_option(opts, :timeout, @default_timeout, operation),
         {:ok, step_timeout} <- Service.positive_option(opts, :step_timeout, timeout, operation) do
      {:ok,
       %{
         subscription_key: subscription_key,
         queue_limit: queue_limit,
         timeout: timeout,
         step_timeout: step_timeout
       }}
    end
  end

  @spec validate_request_options(term(), atom()) ::
          {:ok, request_options()} | {:error, Error.t()}
  def validate_request_options(opts, operation) do
    with :ok <- Service.validate_options(opts, [:timeout, :step_timeout], operation),
         {:ok, timeout} <- Service.positive_option(opts, :timeout, @default_timeout, operation),
         {:ok, step_timeout} <- Service.positive_option(opts, :step_timeout, timeout, operation) do
      {:ok, %{timeout: timeout, step_timeout: step_timeout}}
    end
  end

  @spec subscribe(pid(), AlarmSubscription.alarm_type(), subscription_options()) ::
          {:ok, AlarmSubscription.t()} | {:error, Error.t()}
  def subscribe(connection, alarm_type, options) do
    operation = :subscribe_alarms

    with {:ok, request} <-
           Alarm.subscription_request(alarm_type, options.subscription_key),
         {:ok, token} <-
           Connection.begin_transaction(
             connection,
             operation,
             Service.transaction_options(options)
           ) do
      register_subscription(connection, token, request, alarm_type, options)
    end
  end

  @spec next(pid(), AlarmSubscription.t(), pos_integer()) ::
          {:ok, AlarmEvent.t()} | {:error, Error.t()}
  def next(connection, %AlarmSubscription{} = subscription, timeout)
      when is_pid(connection) and is_integer(timeout) and timeout > 0 do
    with :ok <- validate_connection(subscription, connection, :next_alarm),
         {:ok, message} <-
           Connection.next_userdata(connection, subscription.reference, timeout),
         {:ok, event} <- Alarm.decode_indication(message, :next_alarm) do
      {:ok, event}
    else
      {:error, %Error{} = error} -> {:error, Service.normalize_error(error, :next_alarm)}
    end
  end

  def next(_connection, _subscription, _timeout),
    do: Service.client_error(:next_alarm, :invalid_alarm_subscription)

  @spec unsubscribe(pid(), AlarmSubscription.t(), request_options()) ::
          :ok | {:error, Error.t()}
  def unsubscribe(connection, %AlarmSubscription{} = subscription, options) do
    operation = :unsubscribe_alarms

    with :ok <- validate_connection(subscription, connection, operation),
         {:ok, request} <-
           Alarm.unsubscribe_request(subscription.alarm_type, subscription.subscription_key),
         :ok <- validate_local_subscription(connection, subscription, operation),
         {:ok, token} <-
           Connection.begin_transaction(
             connection,
             operation,
             Service.transaction_options(options)
           ) do
      execute_unsubscribe(connection, token, subscription, request, operation)
    end
  end

  def unsubscribe(_connection, _subscription, _options),
    do: Service.client_error(:unsubscribe_alarms, :invalid_alarm_subscription)

  @spec query(pid(), AlarmQuery.selector(), atom()) ::
          {:ok, AlarmQuery.t()} | {:error, Error.t()}
  def query(connection, selector, operation \\ :query_alarms) do
    with {:ok, request} <- Alarm.query_request(selector),
         {:ok, response} <- Connection.userdata(connection, request, operation),
         {:ok, query} <- Alarm.decode_query_response(response, selector, operation) do
      {:ok, query}
    else
      {:error, %Error{} = error} -> {:error, Service.normalize_error(error, operation)}
    end
  end

  @spec acknowledge(
          pid(),
          AlarmAcknowledgement.t()
          | S7.AlarmEvent.Object.t()
          | AlarmEvent.t()
          | [AlarmAcknowledgement.t() | S7.AlarmEvent.Object.t()],
          request_options(),
          atom()
        ) :: {:ok, [AlarmAcknowledgement.Result.t()]} | {:error, Error.t()}
  def acknowledge(connection, input, options, operation \\ :acknowledge_alarms) do
    with {:ok, acknowledgements} <- Alarm.acknowledgements(input, operation),
         {:ok, request} <- Alarm.acknowledgement_request(acknowledgements) do
      begin_acknowledgement(connection, request, acknowledgements, options, operation)
    else
      {:error, %Error{} = error} -> not_attempted(error, operation)
    end
  end

  defp begin_acknowledgement(connection, request, acknowledgements, options, operation) do
    case Connection.begin_transaction(
           connection,
           operation,
           Service.transaction_options(options)
         ) do
      {:ok, token} ->
        execute_acknowledgement(
          connection,
          token,
          request,
          acknowledgements,
          operation
        )

      {:error, %Error{} = error} ->
        not_attempted(error, operation)
    end
  end

  defp register_subscription(connection, token, request, alarm_type, options) do
    filter = %{
      function_group: :cpu,
      subfunction: {:one_of, Alarm.indication_subfunctions()},
      sequence: 0,
      type: :indication
    }

    case Connection.subscribe_userdata(connection, filter,
           queue_limit: options.queue_limit,
           session_bound: true,
           owner_down_operation: :alarm_subscription
         ) do
      {:ok, reference} ->
        execute_subscribe(
          connection,
          token,
          reference,
          request,
          alarm_type,
          options
        )

      {:error, %Error{} = error} ->
        TransactionCleanup.release(
          connection,
          token,
          Service.normalize_error(error, :subscribe_alarms)
        )
    end
  end

  defp execute_subscribe(
         connection,
         token,
         local_reference,
         request,
         alarm_type,
         options
       ) do
    result =
      with {:ok, response} <- transaction_userdata(connection, token, request),
           :ok <-
             Alarm.decode_subscription_response(
               response,
               request,
               response.header.pdu_reference,
               alarm_type,
               :subscribe,
               :subscribe_alarms
             ),
           :ok <- Connection.end_transaction(connection, token) do
        {:ok,
         %AlarmSubscription{
           connection: connection,
           reference: local_reference,
           alarm_type: alarm_type,
           subscription_key: options.subscription_key
         }}
      end

    case result do
      {:ok, %AlarmSubscription{} = subscription} ->
        {:ok, subscription}

      {:error, %Error{} = error} ->
        cleanup_failed_subscribe(connection, token, local_reference, error)
    end
  end

  defp execute_unsubscribe(connection, token, subscription, request, operation) do
    result =
      with {:ok, response} <- transaction_userdata(connection, token, request),
           :ok <-
             Alarm.decode_subscription_response(
               response,
               request,
               response.header.pdu_reference,
               subscription.alarm_type,
               :unsubscribe,
               operation
             ),
           :ok <- Connection.unsubscribe_userdata(connection, subscription.reference) do
        Connection.end_transaction(connection, token)
      end

    case result do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        TransactionCleanup.abort(connection, token, Service.normalize_error(error, operation))
    end
  end

  defp execute_acknowledgement(
         connection,
         token,
         request,
         acknowledgements,
         operation
       ) do
    result =
      with {:ok, response} <- transaction_userdata(connection, token, request),
           {:ok, results} <-
             Alarm.decode_acknowledgement_response(
               response,
               request,
               response.header.pdu_reference,
               acknowledgements,
               operation
             ),
           :ok <- Connection.end_transaction(connection, token) do
        {:ok, results}
      end

    case result do
      {:ok, results} ->
        {:ok, results}

      {:error, %Error{} = error} ->
        finish_acknowledgement_failure(connection, token, error, operation)
    end
  end

  defp cleanup_failed_subscribe(connection, token, local_reference, error) do
    _ = Connection.unsubscribe_userdata(connection, local_reference)
    error = Service.normalize_error(error, :subscribe_alarms)

    if complete_rejection?(error) do
      TransactionCleanup.release(connection, token, error)
    else
      TransactionCleanup.abort(connection, token, error)
    end
  end

  defp finish_acknowledgement_failure(connection, token, %Error{} = error, operation) do
    error = Service.normalize_error(error, operation)

    cond do
      error.reason == :pdu_too_large ->
        TransactionCleanup.release(connection, token, with_outcome(error, :not_attempted))

      complete_rejection?(error) ->
        TransactionCleanup.release(connection, token, with_outcome(error, :rejected))

      true ->
        TransactionCleanup.abort(connection, token, with_outcome(error, :indeterminate))
    end
  end

  defp complete_rejection?(%Error{reason: reason}) do
    reason in [
      :access_denied,
      :address_out_of_range,
      :alarm_subscription_rejected,
      :data_type_inconsistent,
      :data_type_not_supported,
      :hardware_fault,
      :object_not_found,
      :plc_error,
      :userdata_error
    ]
  end

  defp transaction_userdata(connection, token, message) do
    with {:ok, pdu} <- UserData.to_pdu(message, 0) do
      Connection.transaction_request(connection, token, pdu)
    end
  end

  defp validate_local_subscription(connection, subscription, operation) do
    case Connection.validate_userdata_subscription(connection, subscription.reference) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, Service.normalize_error(error, operation)}
    end
  end

  defp validate_connection(%AlarmSubscription{connection: connection}, connection, _operation),
    do: :ok

  defp validate_connection(_subscription, _connection, operation),
    do: Service.client_error(operation, :invalid_alarm_subscription)

  defp subscription_key_option(opts, operation) do
    value = Keyword.get(opts, :subscription_key, Alarm.default_subscription_key())

    if is_binary(value) and byte_size(value) == 8,
      do: {:ok, value},
      else:
        Service.client_error(operation, :invalid_option, %{
          option: :subscription_key,
          value: value
        })
  end

  defp with_outcome(%Error{} = error, outcome),
    do: %{error | details: Map.put(error.details, :outcome, outcome)}

  defp not_attempted(%Error{} = error, operation),
    do:
      {:error,
       error
       |> Service.normalize_error(operation)
       |> with_outcome(:not_attempted)}
end
