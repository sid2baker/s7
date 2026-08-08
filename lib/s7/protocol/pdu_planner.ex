defmodule S7.Protocol.PDUPlanner do
  @moduledoc """
  Exact, order-preserving packing for Read Var and Write Var PDUs.

  A batch is accepted only when both its encoded request and worst-case
  successful response fit the negotiated S7 PDU size.
  """

  alias S7.{Address, Data, Error}

  @default_maximum_items 20
  @job_base_size 12
  @ack_data_base_size 14

  @type write_item :: {Address.t(), binary()}

  @spec plan_read([Address.t()], pos_integer(), keyword()) ::
          {:ok, [[Address.t()]]} | {:error, Error.t()}
  def plan_read(addresses, pdu_size, opts \\ [])

  def plan_read(addresses, pdu_size, opts) when is_list(addresses) and is_list(opts) do
    maximum_items = Keyword.get(opts, :maximum_items, @default_maximum_items)

    with :ok <- validate_inputs(addresses, pdu_size, maximum_items, :read),
         {:ok, payload_sizes} <- read_payload_sizes(addresses) do
      plan(addresses, payload_sizes, pdu_size, maximum_items, :read)
    end
  end

  def plan_read(addresses, pdu_size, _opts),
    do: invalid_plan(:read, %{items: addresses, pdu_size: pdu_size})

  @spec plan_write([write_item()], pos_integer(), keyword()) ::
          {:ok, [[write_item()]]} | {:error, Error.t()}
  def plan_write(items, pdu_size, opts \\ [])

  def plan_write(items, pdu_size, opts) when is_list(items) and is_list(opts) do
    maximum_items = Keyword.get(opts, :maximum_items, @default_maximum_items)

    with :ok <- validate_inputs(items, pdu_size, maximum_items, :write),
         {:ok, payload_sizes} <- write_payload_sizes(items) do
      plan(items, payload_sizes, pdu_size, maximum_items, :write)
    end
  end

  def plan_write(items, pdu_size, _opts),
    do: invalid_plan(:write, %{items: items, pdu_size: pdu_size})

  @doc false
  @spec read_pdu_sizes([Address.t()]) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, Error.t()}
  def read_pdu_sizes(addresses) when is_list(addresses) do
    with {:ok, payload_sizes} <- read_payload_sizes(addresses) do
      {:ok, sizes(payload_sizes, :read)}
    end
  end

  @doc false
  @spec write_pdu_sizes([write_item()]) ::
          {:ok, {pos_integer(), pos_integer()}} | {:error, Error.t()}
  def write_pdu_sizes(items) when is_list(items) do
    with {:ok, payload_sizes} <- write_payload_sizes(items) do
      {:ok, sizes(payload_sizes, :write)}
    end
  end

  defp plan(items, payload_sizes, pdu_size, maximum_items, operation) do
    initial = %{batches: [], items: [], payload_sizes: []}

    items
    |> Enum.zip(payload_sizes)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, initial}, fn {{item, payload_size}, index}, {:ok, state} ->
      add_to_plan(state, item, payload_size, pdu_size, maximum_items, operation, index)
    end)
    |> finish_plan()
  end

  defp add_to_plan(state, item, payload_size, pdu_size, maximum_items, operation, index) do
    candidate_items = [item | state.items]
    candidate_sizes = [payload_size | state.payload_sizes]
    count = length(candidate_items)
    {request_size, response_size} = sizes(Enum.reverse(candidate_sizes), operation)

    cond do
      count <= maximum_items and request_size <= pdu_size and response_size <= pdu_size ->
        {:cont, {:ok, %{state | items: candidate_items, payload_sizes: candidate_sizes}}}

      state.items == [] ->
        {:halt, item_too_large(operation, index, request_size, response_size, pdu_size)}

      true ->
        state = finish_batch(state)
        {single_request, single_response} = sizes([payload_size], operation)

        if single_request <= pdu_size and single_response <= pdu_size do
          {:cont, {:ok, %{state | items: [item], payload_sizes: [payload_size]}}}
        else
          {:halt, item_too_large(operation, index, single_request, single_response, pdu_size)}
        end
    end
  end

  defp finish_plan({:ok, %{items: []} = state}), do: {:ok, Enum.reverse(state.batches)}

  defp finish_plan({:ok, state}) do
    state = finish_batch(state)
    {:ok, Enum.reverse(state.batches)}
  end

  defp finish_plan({:error, error}), do: {:error, error}

  defp finish_batch(state) do
    batch = Enum.reverse(state.items)
    %{state | batches: [batch | state.batches], items: [], payload_sizes: []}
  end

  defp sizes(payload_sizes, :read) do
    count = length(payload_sizes)
    request_size = @job_base_size + 12 * count
    response_size = @ack_data_base_size + aligned_data_size(payload_sizes)
    {request_size, response_size}
  end

  defp sizes(payload_sizes, :write) do
    count = length(payload_sizes)
    request_size = @job_base_size + 12 * count + aligned_data_size(payload_sizes)
    response_size = @ack_data_base_size + count
    {request_size, response_size}
  end

  defp aligned_data_size([]), do: 0

  defp aligned_data_size(payload_sizes) do
    last_index = length(payload_sizes) - 1

    payload_sizes
    |> Enum.with_index()
    |> Enum.reduce(0, fn {payload_size, index}, size ->
      padding = if index < last_index and rem(payload_size, 2) == 1, do: 1, else: 0
      size + 4 + payload_size + padding
    end)
  end

  defp read_payload_sizes(addresses) do
    addresses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {address, index}, {:ok, sizes} ->
      with %Address{} <- address,
           {:ok, address} <- Address.validate(address),
           {:ok, size} <- Data.encoded_size(address.data_type, address.count) do
        {:cont, {:ok, [size | sizes]}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, add_index(error, index)}}
        _other -> {:halt, invalid_plan(:read, %{index: index, item: address})}
      end
    end)
    |> reverse_sizes()
  end

  defp write_payload_sizes(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {{%Address{} = address, value}, index}, {:ok, sizes} when is_binary(value) ->
        with {:ok, address} <- Address.validate(address),
             {:ok, _value} <- Data.validate_raw(address.data_type, value, address.count) do
          {:cont, {:ok, [byte_size(value) | sizes]}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, add_index(error, index)}}
        end

      {item, index}, _accumulator ->
        {:halt, invalid_plan(:write, %{index: index, item: item})}
    end)
    |> reverse_sizes()
  end

  defp reverse_sizes({:ok, sizes}), do: {:ok, Enum.reverse(sizes)}
  defp reverse_sizes({:error, error}), do: {:error, error}

  defp validate_inputs([], _pdu_size, _maximum_items, operation),
    do: invalid_plan(operation, %{reason: :empty_items})

  defp validate_inputs(_items, pdu_size, maximum_items, _operation)
       when is_integer(pdu_size) and pdu_size > 0 and is_integer(maximum_items) and
              maximum_items in 1..0xFF,
       do: :ok

  defp validate_inputs(_items, pdu_size, maximum_items, operation),
    do: invalid_plan(operation, %{pdu_size: pdu_size, maximum_items: maximum_items})

  defp item_too_large(operation, index, request_size, response_size, pdu_size) do
    {:error,
     Error.new(:s7, operation, :pdu_too_large,
       details: %{
         index: index,
         request_size: request_size,
         response_size: response_size,
         negotiated_size: pdu_size
       }
     )}
  end

  defp invalid_plan(operation, details),
    do: {:error, Error.new(:s7, operation, :invalid_items, details: details)}

  defp add_index(error, index), do: %{error | details: Map.put(error.details, :index, index)}
end
