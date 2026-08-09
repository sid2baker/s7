defmodule S7.Cyclic do
  @moduledoc """
  Classic fixed-cycle and change-driven subscriptions.

  Typed subscriptions use ordinary addresses. Raw subscriptions accept
  complete S7ANY or DBREAD variable specifications for CPU-specific layouts.
  The subscribing process receives updates as
  `{:s7, subscription.reference, %S7.Cyclic.Event{}}` messages.
  """

  alias S7.{API, Error}
  alias S7.Connection.Cyclic, as: Runtime
  alias S7.Cyclic.Subscription

  @type message :: {:s7, reference(), S7.Cyclic.Event.t() | {:error, Error.t()}}

  @doc """
  Starts a fixed-interval subscription for typed addresses.

  The calling process owns the returned handle. The setup snapshot and later
  updates arrive as `{:s7, subscription.reference, event}`. Decode or
  connection failures arrive in the event position as `{:error, %S7.Error{}}`.

  Options are `:interval`, `:timeout`, and `:step_timeout`.
  """
  @spec subscribe(S7.t(), [S7.address()], keyword()) ::
          {:ok, Subscription.t()} | {:error, Error.t()}
  def subscribe(client, addresses, opts \\ []) do
    with {:ok, addresses} <- API.addresses(addresses, :subscribe_cyclic),
         {:ok, options} <- Runtime.validate_subscribe_options(opts, :subscribe_cyclic) do
      API.call(fn -> Runtime.subscribe(client, addresses, options) end, :subscribe_cyclic)
    end
  end

  @doc """
  Starts a raw fixed-cycle or change-driven subscription.

  Delivery and ownership match `subscribe/3`. Item specifications must be
  complete S7ANY or DBREAD binaries.
  """
  @spec subscribe_raw(S7.t(), Subscription.mode(), [binary()], keyword()) ::
          {:ok, Subscription.t()} | {:error, Error.t()}
  def subscribe_raw(client, mode, item_specs, opts \\ []) do
    with {:ok, options} <- Runtime.validate_subscribe_options(opts, :subscribe_cyclic_raw) do
      API.call(
        fn -> Runtime.subscribe_raw(client, mode, item_specs, options) end,
        :subscribe_cyclic_raw
      )
    end
  end

  @doc """
  Replaces the item set of an active raw change-driven subscription.

  The returned handle retains the same reference. The modification snapshot
  and subsequent updates use that reference in owner messages.
  """
  @spec modify_raw(Subscription.t(), [binary()], keyword()) ::
          {:ok, Subscription.t()} | {:error, Error.t()}
  def modify_raw(subscription, item_specs, opts \\ [])

  def modify_raw(%Subscription{connection: connection} = subscription, item_specs, opts) do
    with {:ok, options} <-
           Runtime.validate_modify_options(opts, subscription.interval, :modify_cyclic) do
      API.call(
        fn -> Runtime.modify(connection, subscription, item_specs, options) end,
        :modify_cyclic
      )
    end
  end

  def modify_raw(_subscription, _item_specs, _opts),
    do: {:error, Error.new(:client, :modify_cyclic, :invalid_cyclic_subscription)}

  @doc """
  Releases the remote cyclic job and local subscription state.
  """
  @spec unsubscribe(Subscription.t(), keyword()) :: :ok | {:error, Error.t()}
  def unsubscribe(subscription, opts \\ [])

  def unsubscribe(%Subscription{connection: connection} = subscription, opts) do
    with {:ok, options} <- Runtime.validate_unsubscribe_options(opts, :unsubscribe_cyclic) do
      API.call(
        fn -> Runtime.unsubscribe(connection, subscription, options) end,
        :unsubscribe_cyclic
      )
    end
  end

  def unsubscribe(_subscription, _opts),
    do: {:error, Error.new(:client, :unsubscribe_cyclic, :invalid_cyclic_subscription)}
end
