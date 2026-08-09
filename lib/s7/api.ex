defmodule S7.API do
  @moduledoc false

  alias S7.{Address, Data, Error}

  @spec call((-> result), atom()) :: result when result: term()
  def call(function, operation) do
    function.()
  catch
    :exit, {:noproc, _details} ->
      {:error, Error.new(:client, operation, :connection_closed)}

    :exit, {:normal, _details} ->
      {:error, Error.new(:client, operation, :connection_closed)}

    :exit, reason ->
      {:error, Error.new(:client, operation, :connection_process_exit, code: reason)}
  end

  @spec address(S7.address()) :: {:ok, Address.t()} | {:error, Error.t()}
  def address(address) when is_binary(address), do: Address.parse(address)
  def address(%Address{} = address), do: Address.validate(address)

  def address(address) do
    {:error, Error.new(:address, :parse, :invalid_address, details: %{address: address})}
  end

  @spec addresses(term(), atom()) :: {:ok, [Address.t()]} | {:error, Error.t()}
  def addresses(addresses, _operation) when is_list(addresses) and addresses != [] do
    addresses
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {address, index}, {:ok, normalized} ->
      case address(address) do
        {:ok, address} -> {:cont, {:ok, [address | normalized]}}
        {:error, %Error{} = error} -> {:halt, {:error, add_item_context(error, index)}}
      end
    end)
    |> reverse_normalized()
  end

  def addresses(addresses, operation) do
    {:error, Error.new(:client, operation, :invalid_items, details: %{items: addresses})}
  end

  @spec write_items(term(), :typed | :raw, atom()) ::
          {:ok, [{Address.t(), binary()}]} | {:error, Error.t()}
  def write_items(items, mode, operation) when is_list(items) and items != [] do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn
      {{address, value}, index}, {:ok, normalized} ->
        with {:ok, address} <- address(address),
             {:ok, encoded} <- encode_write_value(address, value, mode) do
          {:cont, {:ok, [{address, encoded} | normalized]}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, add_item_context(error, index)}}
        end

      {item, index}, _accumulator ->
        error = Error.new(:client, operation, :invalid_item, details: %{index: index, item: item})
        {:halt, {:error, error}}
    end)
    |> reverse_normalized()
  end

  def write_items(items, _mode, operation) do
    {:error, Error.new(:client, operation, :invalid_items, details: %{items: items})}
  end

  defp encode_write_value(address, value, :typed),
    do: Data.encode(address.data_type, value, address.count)

  defp encode_write_value(address, value, :raw),
    do: Data.validate_raw(address.data_type, value, address.count)

  defp reverse_normalized({:ok, normalized}), do: {:ok, Enum.reverse(normalized)}
  defp reverse_normalized({:error, error}), do: {:error, error}

  defp add_item_context(error, index),
    do: %{error | details: Map.put(error.details, :index, index)}
end
