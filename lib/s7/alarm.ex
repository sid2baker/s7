defmodule S7.Alarm do
  @moduledoc """
  Classic `ALARM_S` and `ALARM_8` subscriptions, queries, and acknowledgments.
  """

  alias S7.Alarm.{Acknowledgement, Event, Query, Subscription}
  alias S7.{API, Error}
  alias S7.Connection.Alarm, as: Runtime

  @doc """
  Starts a connection-scoped classic alarm subscription.
  """
  @spec subscribe(S7.t(), Subscription.alarm_type(), keyword()) ::
          {:ok, Subscription.t()} | {:error, Error.t()}
  def subscribe(client, alarm_type, opts \\ []) do
    with {:ok, options} <- Runtime.validate_subscription_options(opts, :subscribe_alarms) do
      API.call(fn -> Runtime.subscribe(client, alarm_type, options) end, :subscribe_alarms)
    end
  end

  @doc """
  Pulls the next alarm indication currently associated with a subscription.

  This temporary pull API is replaced by direct owner messages in the next
  pre-release migration milestone.
  """
  @spec next(Subscription.t(), pos_integer()) :: {:ok, Event.t()} | {:error, Error.t()}
  def next(subscription, timeout \\ 5_000)

  def next(%Subscription{connection: connection} = subscription, timeout) do
    API.call(fn -> Runtime.next(connection, subscription, timeout) end, :next_alarm)
  end

  def next(_subscription, _timeout),
    do: {:error, Error.new(:client, :next_alarm, :invalid_alarm_subscription)}

  @doc """
  Releases the remote alarm subscription and local subscription state.
  """
  @spec unsubscribe(Subscription.t(), keyword()) :: :ok | {:error, Error.t()}
  def unsubscribe(subscription, opts \\ [])

  def unsubscribe(%Subscription{connection: connection} = subscription, opts) do
    with {:ok, options} <- Runtime.validate_request_options(opts, :unsubscribe_alarms) do
      API.call(
        fn -> Runtime.unsubscribe(connection, subscription, options) end,
        :unsubscribe_alarms
      )
    end
  end

  def unsubscribe(_subscription, _opts),
    do: {:error, Error.new(:client, :unsubscribe_alarms, :invalid_alarm_subscription)}

  @doc """
  Queries buffered alarms by alarm family or event ID.
  """
  @spec query(S7.t(), Subscription.alarm_type() | 0..0xFFFFFFFF) ::
          {:ok, Query.t()} | {:error, Error.t()}
  def query(client, alarm_type) when alarm_type in [:alarm_s, :alarm_8] do
    API.call(fn -> Runtime.query(client, {:alarm_type, alarm_type}) end, :query_alarms)
  end

  def query(client, event_id) do
    API.call(fn -> Runtime.query(client, {:event_id, event_id}, :query_alarm) end, :query_alarm)
  end

  @doc """
  Explicitly acknowledges one alarm object or acknowledgment value.
  """
  @spec acknowledge(S7.t(), Acknowledgement.t() | Event.Object.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def acknowledge(client, acknowledgement, opts \\ []) do
    with {:ok, options} <- Runtime.validate_request_options(opts, :acknowledge_alarm),
         {:ok, results} <-
           API.call(
             fn -> Runtime.acknowledge(client, acknowledgement, options, :acknowledge_alarm) end,
             :acknowledge_alarm
           ) do
      single_result(results)
    end
  end

  @doc """
  Explicitly acknowledges every object in an alarm event or list.
  """
  @spec acknowledge_many(
          S7.t(),
          Event.t() | [Acknowledgement.t() | Event.Object.t()],
          keyword()
        ) :: {:ok, [Acknowledgement.Result.t()]} | {:error, Error.t()}
  def acknowledge_many(client, acknowledgements, opts \\ []) do
    with {:ok, options} <- Runtime.validate_request_options(opts, :acknowledge_alarms) do
      API.call(
        fn -> Runtime.acknowledge(client, acknowledgements, options, :acknowledge_alarms) end,
        :acknowledge_alarms
      )
    end
  end

  defp single_result([%Acknowledgement.Result{status: :ok}]), do: :ok

  defp single_result([%Acknowledgement.Result{status: :error, error: %Error{} = error}]),
    do: {:error, %{error | operation: :acknowledge_alarm}}

  defp single_result(_results),
    do: {:error, Error.new(:client, :acknowledge_alarm, :invalid_alarm_acknowledgement)}
end
