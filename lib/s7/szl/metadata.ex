defmodule S7.SZL.Metadata do
  @moduledoc false

  import Bitwise

  alias S7.{PLC, SZL}

  @spec available_ids(SZL.t()) :: {:ok, [0..0xFFFF]} | {:error, S7.Error.t()}
  def available_ids(%SZL{id: 0, record_length: 2, records: records}) do
    {:ok, Enum.map(records, fn <<id::unsigned-big-16>> -> id end)}
  end

  def available_ids(%SZL{} = szl),
    do: SZL.malformed(:list_szl, %{id: szl.id, record_length: szl.record_length})

  @spec order_code(SZL.t()) :: {:ok, PLC.OrderCode.t()} | {:error, S7.Error.t()}
  def order_code(%SZL{} = szl) do
    with :ok <- require_sublist(szl, 0x11, :order_code),
         {:ok, record} <- component_record(szl, 0x01, :order_code),
         <<_index::16, code::binary-size(20), _module_type::16, version_1::16, version_23::16,
           _rest::binary>> <- record do
      {:ok,
       %PLC.OrderCode{
         code: decode_text(code),
         version: {version_1 &&& 0xFF, version_23 >>> 8, version_23 &&& 0xFF},
         record: record
       }}
    else
      {:error, _error} = error -> error
      _malformed -> SZL.malformed(:order_code, %{record_length: szl.record_length})
    end
  end

  @spec cpu_info(SZL.t()) :: {:ok, PLC.CPUInfo.t()} | {:error, S7.Error.t()}
  def cpu_info(%SZL{} = szl) do
    with :ok <- require_sublist(szl, 0x1C, :cpu_info),
         :ok <- require_record_length(szl, 34, :cpu_info) do
      components = Map.new(szl.records, fn <<index::16, value::binary>> -> {index, value} end)

      {:ok,
       %PLC.CPUInfo{
         automation_system_name: component_text(components, 0x01, 24),
         module_name: component_text(components, 0x02, 24),
         copyright: component_text(components, 0x04, 26),
         serial_number: component_text(components, 0x05, 24),
         module_type_name: component_text(components, 0x07, 32),
         components: components
       }}
    end
  end

  @spec cp_info(SZL.t()) :: {:ok, PLC.CPInfo.t()} | {:error, S7.Error.t()}
  def cp_info(%SZL{} = szl) do
    with :ok <- require_sublist(szl, 0x31, :cp_info),
         {:ok, record} <- component_record(szl, 0x01, :cp_info),
         <<_index::16, max_pdu_length::16, max_connections::16, max_mpi_rate::32,
           max_bus_rate::32, _rest::binary>> <- record do
      {:ok,
       %PLC.CPInfo{
         max_pdu_length: max_pdu_length,
         max_connections: max_connections,
         max_mpi_rate: max_mpi_rate,
         max_bus_rate: max_bus_rate,
         record: record
       }}
    else
      {:error, _error} = error -> error
      _malformed -> SZL.malformed(:cp_info, %{record_length: szl.record_length})
    end
  end

  @spec plc_status(SZL.t()) :: {:ok, PLC.Status.t()} | {:error, S7.Error.t()}
  def plc_status(%SZL{} = szl) do
    with :ok <- require_sublist(szl, 0x24, :plc_status),
         [record | _records] <- szl.records,
         <<_index::16, _reserved, code, _rest::binary>> <- record do
      {:ok, %PLC.Status{state: status(code), code: code, record: record}}
    else
      {:error, _error} = error -> error
      _malformed -> SZL.malformed(:plc_status, %{record_length: szl.record_length})
    end
  end

  defp require_sublist(szl, expected, operation) do
    if SZL.sublist(szl) == expected do
      :ok
    else
      SZL.malformed(operation, %{id: szl.id, expected_sublist: expected})
    end
  end

  defp require_record_length(%SZL{record_length: length}, minimum, _operation)
       when length >= minimum,
       do: :ok

  defp require_record_length(%SZL{record_length: length}, minimum, operation),
    do: SZL.malformed(operation, %{record_length: length, minimum: minimum})

  defp component_record(szl, component, operation) do
    case SZL.record_by_index(szl, component) do
      {:ok, record} ->
        {:ok, record}

      :error ->
        case packed_component_record(szl.records, component) do
          nil -> SZL.malformed(operation, %{missing_component: component})
          record -> {:ok, record}
        end
    end
  end

  defp component_text(components, component, length) do
    case component_value(components, component) do
      nil -> nil
      value when byte_size(value) >= length -> value |> binary_part(0, length) |> decode_text()
      value -> decode_text(value)
    end
  end

  defp packed_component_record(records, component) do
    records
    |> Enum.filter(fn
      <<index::unsigned-big-16, _rest::binary>> -> (index &&& 0xFF) == component
      _record -> false
    end)
    |> Enum.min_by(
      fn <<index::unsigned-big-16, _rest::binary>> -> component_rank(index) end,
      fn -> nil end
    )
  end

  defp component_value(components, component) do
    case Map.fetch(components, component) do
      {:ok, value} ->
        value

      :error ->
        components
        |> Enum.filter(fn {index, _value} -> (index &&& 0xFF) == component end)
        |> Enum.min_by(fn {index, _value} -> component_rank(index) end, fn -> nil end)
        |> case do
          nil -> nil
          {_index, value} -> value
        end
    end
  end

  defp component_rank(index) do
    high_byte = index >>> 8
    master_rank = if (high_byte &&& 0x08) == 0x08, do: 0, else: 1
    {master_rank, index}
  end

  defp decode_text(binary) do
    binary
    |> :binary.split(<<0>>)
    |> hd()
    |> :unicode.characters_to_binary(:latin1, :utf8)
    |> String.trim_trailing()
  end

  defp status(0x08), do: :run
  defp status(code) when code in [0x03, 0x04], do: :stop
  defp status(_code), do: :unknown
end
