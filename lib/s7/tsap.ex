defmodule S7.TSAP do
  @moduledoc """
  Constructs Siemens destination TSAPs independently from COTP encoding.
  """

  alias S7.Error

  @connection_types %{
    programming_device: 0x01,
    operator_panel: 0x02,
    basic: 0x03
  }

  @type connection_type :: :programming_device | :operator_panel | :basic

  @doc """
  Builds a two-byte destination TSAP and raises `ArgumentError` for invalid
  options. Use `build/1` when input is not trusted.
  """
  @spec for_rack_slot(keyword()) :: <<_::16>>
  def for_rack_slot(opts) do
    case build(opts) do
      {:ok, tsap} -> tsap
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc """
  Safely builds a destination TSAP from rack, slot, and connection type.
  """
  @spec build(keyword()) :: {:ok, <<_::16>>} | {:error, Error.t()}
  def build(opts) when is_list(opts) do
    rack = Keyword.get(opts, :rack, 0)
    slot = Keyword.get(opts, :slot, 2)
    connection_type = Keyword.get(opts, :connection_type, :programming_device)

    with {:ok, type_code} <- connection_type_code(connection_type),
         :ok <- validate_rack(rack),
         :ok <- validate_slot(slot) do
      {:ok, <<type_code, rack * 0x20 + slot>>}
    else
      {:error, reason, details} ->
        {:error, Error.new(:cotp, :build_tsap, reason, details: details)}
    end
  end

  def build(opts) do
    {:error, Error.new(:cotp, :build_tsap, :invalid_options, details: %{options: opts})}
  end

  defp connection_type_code(type) do
    case @connection_types do
      %{^type => code} -> {:ok, code}
      _ -> {:error, :invalid_connection_type, %{connection_type: type}}
    end
  end

  defp validate_rack(rack) when is_integer(rack) and rack in 0..7, do: :ok
  defp validate_rack(rack), do: {:error, :invalid_rack, %{rack: rack}}

  defp validate_slot(slot) when is_integer(slot) and slot in 0..31, do: :ok
  defp validate_slot(slot), do: {:error, :invalid_slot, %{slot: slot}}
end
