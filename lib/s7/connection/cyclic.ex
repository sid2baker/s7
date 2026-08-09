defmodule S7.Connection.Cyclic do
  @moduledoc false

  alias S7.Address
  alias S7.Connection
  alias S7.Connection.{Service, TransactionCleanup}
  alias S7.Cyclic, as: CyclicModel
  alias S7.Error
  alias S7.Protocol.{Cyclic, UserData}

  @default_timeout 5_000
  @type subscribe_options :: %{
          interval: CyclicModel.Interval.t(),
          timeout: pos_integer(),
          step_timeout: pos_integer()
        }

  @type request_options :: %{
          interval: CyclicModel.Interval.t() | nil,
          timeout: pos_integer(),
          step_timeout: pos_integer()
        }

  @spec validate_subscribe_options(term(), atom()) ::
          {:ok, subscribe_options()} | {:error, Error.t()}
  def validate_subscribe_options(opts, operation) do
    with :ok <-
           Service.validate_options(
             opts,
             [:interval, :timeout, :step_timeout],
             operation
           ),
         {:ok, interval} <- Cyclic.interval(Keyword.get(opts, :interval, 1_000), operation),
         {:ok, timeout} <- Service.positive_option(opts, :timeout, @default_timeout, operation),
         {:ok, step_timeout} <- Service.positive_option(opts, :step_timeout, timeout, operation) do
      {:ok,
       %{
         interval: interval,
         timeout: timeout,
         step_timeout: step_timeout
       }}
    end
  end

  @spec validate_modify_options(term(), CyclicModel.Interval.t(), atom()) ::
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
          {:ok, CyclicModel.Subscription.t()} | {:error, Error.t()}
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
          CyclicModel.Subscription.mode(),
          [binary()],
          subscribe_options()
        ) :: {:ok, CyclicModel.Subscription.t()} | {:error, Error.t()}
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

  @spec modify(pid(), CyclicModel.Subscription.t(), [binary()], request_options()) ::
          {:ok, CyclicModel.Subscription.t()} | {:error, Error.t()}
  def modify(
        connection,
        %CyclicModel.Subscription{mode: :change_driven} = subscription,
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

  @spec unsubscribe(pid(), CyclicModel.Subscription.t(), request_options()) ::
          :ok | {:error, Error.t()}
  def unsubscribe(connection, %CyclicModel.Subscription{} = subscription, options) do
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
           subscription = %CyclicModel.Subscription{
             connection: connection,
             reference: local_reference,
             job_id: job_id,
             mode: context.mode,
             interval: context.options.interval,
             item_specs: context.item_specs,
             typed?: context.typed?,
             addresses: context.addresses
           },
           :ok <-
             Connection.activate_userdata_subscription(
               connection,
               local_reference,
               subscription_filter(job_id, context.mode),
               {:messages, :cyclic, subscription},
               initial
             ),
           :ok <- Connection.end_transaction(connection, token) do
        {:ok, subscription}
      end

    case result do
      {:ok, %CyclicModel.Subscription{} = subscription} ->
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
    updated = %{
      subscription
      | interval: options.interval,
        item_specs: item_specs
    }

    result =
      with :ok <-
             Connection.activate_userdata_subscription(
               connection,
               subscription.reference,
               subscription_filter(updated.job_id, updated.mode),
               {:messages, :cyclic, updated}
             ),
           {:ok, response} <- transaction_userdata(connection, token, request),
           {:ok, initial} <-
             Cyclic.decode_modify_response(
               response,
               request,
               response.header.pdu_reference,
               subscription.job_id,
               length(item_specs),
               operation
             ),
           :ok <-
             Connection.activate_userdata_subscription(
               connection,
               subscription.reference,
               subscription_filter(updated.job_id, updated.mode),
               {:messages, :cyclic, updated},
               initial
             ),
           :ok <- Connection.end_transaction(connection, token) do
        {:ok, updated}
      end

    case result do
      {:ok, %CyclicModel.Subscription{} = updated} ->
        {:ok, updated}

      {:error, %Error{} = error} ->
        finish_modify_failure(connection, token, subscription, error)
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

  defp finish_modify_failure(connection, token, subscription, %Error{} = error) do
    error = Service.normalize_error(error, :modify_cyclic)

    if complete_rejection?(error) do
      _ =
        Connection.activate_userdata_subscription(
          connection,
          subscription.reference,
          subscription_filter(subscription.job_id, subscription.mode),
          {:messages, :cyclic, subscription}
        )

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

  defp validate_connection(
         %CyclicModel.Subscription{connection: connection},
         connection,
         _operation
       ),
       do: :ok

  defp validate_connection(_subscription, _connection, operation),
    do: Service.client_error(operation, :invalid_cyclic_subscription)
end
