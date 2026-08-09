defmodule S7.Protocol.PIService do
  @moduledoc """
  Pure codecs for classic PI-Service Job requests.

  The currently modeled block actions activate a downloaded passive image or
  remove a block. Both operations are destructive and policy is enforced by
  `S7.Client`, not by this wire codec.
  """

  alias S7.{Block, Error}
  alias S7.Protocol.{Job, PDU}

  @function 0x28
  @block_actions %{
    insert: {0x50, "_INSE"},
    delete: {0x42, "_DELE"}
  }

  @type block_action :: :insert | :delete

  @doc false
  @spec block_request(Block.t(), block_action(), atom()) ::
          {:ok, PDU.t()} | {:error, Error.t()}
  def block_request(%Block{} = block, action, operation)
      when is_map_key(@block_actions, action) do
    with {:ok, %Block{} = block} <- Block.validate(block, operation) do
      {subfunction, command} = Map.fetch!(@block_actions, action)
      <<_prefix, block_type>> = Block.encode_type(block.type)
      number = block.number |> Integer.to_string() |> String.pad_leading(5, "0")

      parameters =
        IO.iodata_to_binary([
          <<@function, 0::48, 0xFD, 10::unsigned-big-16, 1, 0, ?0, block_type>>,
          number,
          <<subfunction, 5>>,
          command
        ])

      {:ok, PDU.new(:job, 0, parameters)}
    end
  end

  def block_request(_block, _action, operation),
    do: {:error, Error.new(:client, operation, :invalid_block_request)}

  @doc false
  @spec decode_block_request(PDU.t(), atom()) ::
          {:ok, %{action: block_action(), block: Block.t()}} | {:error, Error.t()}
  def decode_block_request(
        %PDU{
          header: %{rosctr: :job},
          parameters:
            <<@function, 0::48, 0xFD, 10::unsigned-big-16, 1, 0, ?0, block_type,
              number::binary-size(5), subfunction, 5, command::binary-size(5)>>,
          data: <<>>
        },
        operation
      ) do
    with {:ok, action} <- decode_action(subfunction, command, operation),
         {:ok, block} <- decode_block(block_type, number, operation) do
      {:ok, %{action: action, block: block}}
    end
  end

  def decode_block_request(_pdu, operation), do: malformed(operation, %{})

  @doc false
  @spec decode_response(PDU.t(), atom()) :: :ok | {:error, Error.t()}
  def decode_response(%PDU{} = pdu, operation) do
    with :ok <- validate_header(pdu, operation),
         <<@function>> <- pdu.parameters,
         <<>> <- pdu.data do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}

      _other ->
        malformed(operation, %{parameters: pdu.parameters, data_size: byte_size(pdu.data)})
    end
  end

  def decode_response(_pdu, operation), do: malformed(operation, %{})

  @doc false
  @spec complete_rejection?(Error.t()) :: boolean()
  def complete_rejection?(%Error{} = error), do: Job.complete_rejection?(error)

  defp decode_action(subfunction, command, operation) do
    case Enum.find(@block_actions, fn {_action, wire} -> wire == {subfunction, command} end) do
      {action, _wire} -> {:ok, action}
      nil -> malformed(operation, %{subfunction: subfunction, command: command})
    end
  end

  defp decode_block(block_type, number, operation) do
    with {number, ""} <- Integer.parse(number),
         type when is_atom(type) <- Block.decode_type(?0 * 256 + block_type),
         {:ok, block} <- Block.normalize(type, number, operation) do
      {:ok, block}
    else
      _other -> malformed(operation, %{block_type: block_type, number: number})
    end
  end

  defp validate_header(pdu, operation), do: Job.validate_response_header(pdu, operation)

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_response, details: details)}
end
