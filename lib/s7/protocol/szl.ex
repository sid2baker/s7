defmodule S7.Protocol.SZL do
  @moduledoc """
  Pure request and bounded fragment assembly for classic Read SZL userdata.
  """

  alias S7.{Error, SZL}
  alias S7.Protocol.SZL.Transaction
  alias S7.Protocol.UserData
  alias S7.Protocol.UserData.{Parameter, Payload}

  @subfunction 0x01
  @octet_string 0x09

  @typep consume_result ::
           {:ok, SZL.t()}
           | {:continue, UserData.t(), Transaction.t()}
           | {:error, Error.t()}

  @doc false
  @spec start(0..0xFFFF, 0..0xFFFF, S7.SZL.limits()) ::
          {:ok, UserData.t(), Transaction.t()} | {:error, Error.t()}
  def start(id, index, %{max_bytes: max_bytes, max_fragments: max_fragments} = limits)
      when id in 0..0xFFFF and index in 0..0xFFFF and is_integer(max_bytes) and max_bytes > 0 and
             is_integer(max_fragments) and max_fragments > 0 do
    with {:ok, request} <- UserData.request(:cpu, @subfunction, <<id::16, index::16>>) do
      transaction =
        struct!(Transaction, Map.merge(limits, %{id: id, index: index}))

      {:ok, request, transaction}
    end
  end

  def start(_id, _index, _limits),
    do: {:error, Error.new(:client, :read_szl, :invalid_szl_request)}

  @doc false
  @spec consume(UserData.t(), Transaction.t(), atom()) :: consume_result()
  def consume(%UserData{} = response, %Transaction{} = transaction, operation) do
    with :ok <- validate_transport(response.payload, operation),
         {:ok, chunk} <- fragment_data(response, transaction, operation),
         {:ok, data_unit_reference, more?} <-
           fragment_parameters(response.parameter, transaction, operation),
         {:ok, transaction} <-
           append_fragment(transaction, chunk, data_unit_reference, more?, operation) do
      finish_or_continue(response, transaction, more?, operation)
    end
  end

  def consume(_response, _transaction, operation), do: SZL.malformed(operation, %{})

  defp validate_transport(%Payload{transport_size: @octet_string}, _operation), do: :ok

  defp validate_transport(%Payload{transport_size: transport_size}, operation),
    do: SZL.malformed(operation, %{transport_size: transport_size})

  defp fragment_data(%UserData{payload: %Payload{data: data}}, transaction, operation)
       when transaction.fragment_count == 0 do
    case data do
      <<id::unsigned-big-16, index::unsigned-big-16, chunk::binary>> ->
        if id == transaction.id and index == transaction.index do
          {:ok, chunk}
        else
          SZL.malformed(operation, %{
            expected: {transaction.id, transaction.index},
            received: {id, index}
          })
        end

      _other ->
        SZL.malformed(operation, %{bytes_needed: max(4 - byte_size(data), 0)})
    end
  end

  defp fragment_data(%UserData{payload: %Payload{data: data}}, _transaction, _operation),
    do: {:ok, data}

  defp fragment_parameters(
         %Parameter{
           data_unit_reference: data_unit_reference,
           last_data_unit: last_data_unit,
           error_code: error_code
         },
         transaction,
         operation
       )
       when data_unit_reference in 0..0xFF and last_data_unit in 0..0xFF and error_code == 0 do
    case transaction.data_unit_reference do
      nil ->
        {:ok, data_unit_reference, last_data_unit != 0}

      ^data_unit_reference ->
        {:ok, data_unit_reference, last_data_unit != 0}

      expected ->
        SZL.malformed(operation, %{
          expected_data_unit: expected,
          received_data_unit: data_unit_reference
        })
    end
  end

  defp fragment_parameters(_parameter, _transaction, operation),
    do: SZL.malformed(operation, %{parameter_extension: :invalid})

  defp append_fragment(transaction, chunk, data_unit_reference, more?, operation) do
    fragment_count = transaction.fragment_count + 1
    size = transaction.size + byte_size(chunk)

    cond do
      fragment_count > transaction.max_fragments ->
        {:error,
         Error.new(:s7, operation, :too_many_userdata_fragments,
           details: %{limit: transaction.max_fragments}
         )}

      more? and fragment_count >= transaction.max_fragments ->
        {:error,
         Error.new(:s7, operation, :too_many_userdata_fragments,
           details: %{limit: transaction.max_fragments}
         )}

      size > transaction.max_bytes ->
        {:error,
         Error.new(:s7, operation, :userdata_too_large,
           details: %{size: size, limit: transaction.max_bytes}
         )}

      true ->
        {:ok,
         %{
           transaction
           | data_unit_reference: data_unit_reference,
             fragment_count: fragment_count,
             size: size,
             parts: [chunk | transaction.parts]
         }}
    end
  end

  defp finish_or_continue(_response, transaction, false, operation) do
    raw = transaction.parts |> Enum.reverse() |> IO.iodata_to_binary()
    SZL.decode(transaction.id, transaction.index, raw, operation)
  end

  defp finish_or_continue(response, transaction, true, _operation) do
    with {:ok, request} <- continuation_request(response.parameter.sequence) do
      {:continue, request, transaction}
    end
  end

  defp continuation_request(sequence) do
    UserData.request(:cpu, @subfunction, <<>>,
      method: 0x12,
      sequence: sequence,
      data_unit_reference: 0,
      last_data_unit: 0,
      error_code: 0,
      return_code: 0x0A,
      transport_size: 0x00
    )
  end
end
