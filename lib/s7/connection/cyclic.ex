defmodule S7.Connection.Cyclic do
  @moduledoc false

  alias S7.{
    Address,
    Connection,
    CyclicInterval,
    CyclicSubscription,
    Error
  }

  alias S7.Connection.{Service, TransactionCleanup}
  alias S7.Protocol.{Cyclic, UserData}

  @default_timeout 5_000
  @default_queue_limit 64

  @type subscribe_options :: %{
          interval: CyclicInterval.t(),
          queue_limit: pos_integer(),
          timeout: pos_integer(),
          step_timeout: pos_integer()
        }

  @type request_options :: %{
          interval: CyclicInterval.t() | nil,
          timeout: pos_integer(),
          step_timeout: pos_integer()
        }

  @spec validate_subscribe_options(term(), atom()) ::
          {:ok, subscribe_options()} | {:error, Error.t()}
  def validate_subscribe_options(opts, operation) do
    with :ok <-
           Service.validate_options(
             opts,
             [:interval, :queue_limit, :timeout, :step_timeout],
             operation
           ),
         {:ok, interval} <- Cyclic.interval(Keyword.get(opts, :interval, 1_000), operation),
         {:ok, queue_limit} <-
           Service.positive_option(opts, :queue_limit, @default_queue_limit, operation),
         {:ok, timeout} <- Service.positive_option(opts, :timeout, @default_timeout, operation),
         {:ok, step_timeout} <- Service.positive_option(opts, :step_timeout, timeout, operation) do
      {:ok,
       %{
         interval: interval,
         queue_limit: queue_limit,
         timeout: timeout,
         step_timeout: step_timeout
       }}
    end
  end

  @spec validate_modify_options(term(), CyclicInterval.t(), atom()) ::
          {:ok, request_options()} | {:error, Error.t()}
  def validate_modify_options(opts, default_interval, operation) do
    with :ok <- Service.validate_options(opts, [:interval, :timeout, :step_timeout], operation),
         {:ok, interval} <-
           Cyclic.interval(Keyword.get(opts, :interval, default_interval), operation),
         {:ok, timeout} <- Service.positive_option(opts, :timeout, @default_timeout, operation),
         {:ok, step_timeout} <- Service.positive_option(opts, :step_timeout, timeout, operation) do
      {:ok, %{interval: interval, timeout: timeout, step_timeout: step_timeout}}
    end
  end

  @spec validate_unsubscribe_options(term(), atom()) ::
          {:ok, request_options()} | {:error, Error.t()}
  def validate_unsubscribe_options(opts, operation) do
    with :ok <- Service.validate_options(opts, [:timeout, :step_timeout], operation),
         {:ok, timeout} <- Service.positive_option(opts, :timeout, @default_timeout, operation),
         {:ok, step_timeout} <- Service.positive_option(opts, :step_timeout, timeout, operation) do
      {:ok, %{interval: nil, timeout: timeout, step_timeout: step_timeout}}
    end
  end

  @spec subscribe(pid(), [Address.t()], subscribe_options()) ::
          {:ok, CyclicSubscription.t()} | {:error, Error.t()}
  def subscribe(connection, addresses, options) do
    with {:ok, item_specs} <- Cyclic.typed_item_specs(addresses, :subscribe_cyclic),
         {:ok, request} <-
           Cyclic.subscribe_request(
             :cyclic,
             item_specs,
             options.interval,
             :subscribe_cyclic
           ) do
      start_subscription(connection, request, %{
        mode: :cyclic,
        addresses: addresses,
        item_specs: item_specs,
        typed?: true,
        options: options,
        operation: :subscribe_cyclic
      })
    end
  end

  @spec subscribe_raw(
          pid(),
          CyclicSubscription.mode(),
          [binary()],
          subscribe_options()
        ) :: {:ok, CyclicSubscription.t()} | {:error, Error.t()}
  def subscribe_raw(connection, mode, items, options) do
    with {:ok, item_specs} <- Cyclic.raw_item_specs(items, :subscribe_cyclic_raw),
         {:ok, request} <-
           Cyclic.subscribe_request(
             mode,
             item_specs,
             options.interval,
             :subscribe_cyclic_raw
           ) do
      start_subscription(connection, request, %{
        mode: mode,
        addresses: nil,
        item_specs: item_specs,
        typed?: false,
        options: options,
        operation: :subscribe_cyclic_raw
      })
    end
  end

  @spec next(pid(), CyclicSubscription.t(), pos_integer()) ::
          {:ok, S7.CyclicEvent.t()} | {:error, Error.t()}
  def next(connection, %CyclicSubscription{} = subscription, timeout)
      when is_pid(connection) and is_integer(timeout) and timeout > 0 do
    with :ok <- validate_connection(subscription, connection, :next_cyclic),
         {:ok, message} <-
           Connection.next_userdata(connection, subscription.reference, timeout),
         {:ok, event} <- Cyclic.decode_indication(message, subscription, :next_cyclic) do
      {:ok, event}
    else
      {:error, %Error{} = error} -> {:error, Service.normalize_error(error, :next_cyclic)}
    end
  end

  def next(_connection, _subscription, _timeout),
    do: Service.client_error(:next_cyclic, :invalid_cyclic_subscription)

  @spec modify(pid(), CyclicSubscription.t(), [binary()], request_options()) ::
          {:ok, CyclicSubscription.t()} | {:error, Error.t()}
  def modify(
        connection,
        %CyclicSubscription{mode: :change_driven} = subscription,
        items,
        options
      ) do
    operation = :modify_cyclic

    with :ok <- validate_connection(subscription, connection, operation),
         {:ok, item_specs} <- Cyclic.raw_item_specs(items, operation),
         {:ok, request} <-
           Cyclic.modify_request(subscription.job_id, item_specs, options.interval, operation),
         :ok <- validate_local_subscription(connection, subscription, operation),
         {:ok, token} <-
           Connection.begin_transaction(
             connection,
             operation,
             Service.transaction_options(options)
           ) do
      execute_modify(connection, token, subscription, request, item_specs, options, operation)
    end
  end

  def modify(_connection, _subscription, _items, _options),
    do: Service.client_error(:modify_cyclic, :invalid_cyclic_subscription)

  @spec unsubscribe(pid(), CyclicSubscription.t(), request_options()) ::
          :ok | {:error, Error.t()}
  def unsubscribe(connection, %CyclicSubscription{} = subscription, options) do
    operation = :unsubscribe_cyclic

    with :ok <- validate_connection(subscription, connection, operation),
         {:ok, request} <- Cyclic.unsubscribe_request(subscription.job_id, operation),
         :ok <- validate_unsubscribe_subscription(connection, subscription, operation),
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
    do: Service.client_error(:unsubscribe_cyclic, :invalid_cyclic_subscription)

  defp start_subscription(connection, request, context) do
    with {:ok, token} <-
           Connection.begin_transaction(
             connection,
             context.operation,
             Service.transaction_options(context.options)
           ) do
      register_subscription(connection, token, request, context)
    end
  end

  defp register_subscription(connection, token, request, context) do
    filter = %{
      function_group: :cyclic,
      subfunction: subscription_subfunction(context.mode),
      sequence: :any,
      type: :indication
    }

    case Connection.subscribe_userdata(connection, filter,
           queue_limit: context.options.queue_limit,
           session_bound: true,
           owner_down_operation: :cyclic_subscription
         ) do
      {:ok, reference} ->
        execute_subscribe(connection, token, reference, request, context)

      {:error, %Error{} = error} ->
        TransactionCleanup.release(
          connection,
          token,
          Service.normalize_error(error, context.operation)
        )
    end
  end

  defp execute_subscribe(connection, token, local_reference, request, context) do
    result =
      with {:ok, response} <- transaction_userdata(connection, token, request),
           {:ok, job_id, initial} <-
             Cyclic.decode_subscribe_response(
               response,
               request,
               response.header.pdu_reference,
               context.mode,
               context.addresses,
               length(context.item_specs),
               context.operation
             ),
           :ok <-
             Connection.rebind_userdata_subscription(
               connection,
               local_reference,
               subscription_filter(job_id, context.mode)
             ),
           :ok <- Connection.end_transaction(connection, token) do
        {:ok,
         %CyclicSubscription{
           connection: connection,
           reference: local_reference,
           job_id: job_id,
           mode: context.mode,
           interval: context.options.interval,
           item_specs: context.item_specs,
           typed?: context.typed?,
           addresses: context.addresses,
           initial: initial
         }}
      end

    case result do
      {:ok, %CyclicSubscription{} = subscription} ->
        {:ok, subscription}

      {:error, %Error{} = error} ->
        cleanup_failed_subscribe(
          connection,
          token,
          local_reference,
          error,
          context.operation
        )
    end
  end

  defp execute_modify(
         connection,
         token,
         subscription,
         request,
         item_specs,
         options,
         operation
       ) do
    result =
      with {:ok, response} <- transaction_userdata(connection, token, request),
           {:ok, initial} <-
             Cyclic.decode_modify_response(
               response,
               request,
               response.header.pdu_reference,
               subscription.job_id,
               length(item_specs),
               operation
             ),
           :ok <- Connection.end_transaction(connection, token) do
        {:ok,
         %{
           subscription
           | interval: options.interval,
             item_specs: item_specs,
             initial: initial
         }}
      end

    case result do
      {:ok, %CyclicSubscription{} = updated} -> {:ok, updated}
      {:error, %Error{} = error} -> finish_modify_failure(connection, token, error)
    end
  end

  defp execute_unsubscribe(connection, token, subscription, request, operation) do
    result =
      with {:ok, response} <- transaction_userdata(connection, token, request),
           :ok <-
             Cyclic.decode_unsubscribe_response(
               response,
               request,
               response.header.pdu_reference,
               subscription.job_id,
               operation
             ),
           :ok <- Connection.unsubscribe_userdata(connection, subscription.reference) do
        Connection.end_transaction(connection, token)
      end

    case result do
      :ok -> :ok
      {:error, %Error{} = error} -> TransactionCleanup.abort(connection, token, error)
    end
  end

  defp cleanup_failed_subscribe(connection, token, local_reference, error, operation) do
    _ = Connection.unsubscribe_userdata(connection, local_reference)
    error = Service.normalize_error(error, operation)

    if complete_rejection?(error) do
      TransactionCleanup.release(connection, token, error)
    else
      TransactionCleanup.abort(connection, token, error)
    end
  end

  defp finish_modify_failure(connection, token, %Error{} = error) do
    error = Service.normalize_error(error, :modify_cyclic)

    if complete_rejection?(error) do
      TransactionCleanup.release(connection, token, error)
    else
      TransactionCleanup.abort(connection, token, error)
    end
  end

  defp complete_rejection?(%Error{reason: reason}) do
    reason in [
      :access_denied,
      :address_out_of_range,
      :data_type_inconsistent,
      :data_type_not_supported,
      :hardware_fault,
      :invalid_cyclic_interval,
      :object_not_found,
      :pdu_too_large,
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
    case Connection.rebind_userdata_subscription(
           connection,
           subscription.reference,
           subscription_filter(subscription.job_id, subscription.mode)
         ) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, Service.normalize_error(error, operation)}
    end
  end

  defp validate_unsubscribe_subscription(connection, subscription, operation) do
    case Connection.validate_userdata_subscription(connection, subscription.reference) do
      :ok -> :ok
      {:error, %Error{} = error} -> {:error, Service.normalize_error(error, operation)}
    end
  end

  defp subscription_filter(job_id, mode) do
    %{
      function_group: :cyclic,
      subfunction: subscription_subfunction(mode),
      sequence: job_id,
      type: :indication
    }
  end

  defp subscription_subfunction(:cyclic), do: 0x01
  defp subscription_subfunction(:change_driven), do: :any

  defp validate_connection(%CyclicSubscription{connection: connection}, connection, _operation),
    do: :ok

  defp validate_connection(_subscription, _connection, operation),
    do: Service.client_error(operation, :invalid_cyclic_subscription)
end
