defmodule S7.Blocks do
  @moduledoc """
  Classic block directory, metadata, upload, and destructive block operations.

  Destructive functions retain the immutable connection opt-in and exact
  operation-specific confirmation values.
  """

  alias S7.{API, Block, Destructive, Error}
  alias S7.Connection
  alias S7.Connection.Blocks, as: Runtime

  @doc """
  Returns block counts by directory type.
  """
  @spec counts(S7.t()) :: {:ok, Block.Inventory.t()} | {:error, Error.t()}
  def counts(client), do: API.call(fn -> Connection.block_counts(client) end, :block_counts)

  @doc """
  Lists block identities for one block type.
  """
  @spec list(S7.t(), Block.known_type(), keyword()) ::
          {:ok, [Block.Entry.t()]} | {:error, Error.t()}
  def list(client, type, opts \\ []) do
    with {:ok, type} <- Block.validate_request_type(type, :list_blocks),
         {:ok, limits} <- Block.validate_list_options(opts, :list_blocks) do
      API.call(fn -> Connection.list_blocks(client, type, limits) end, :list_blocks)
    end
  end

  @doc """
  Reads detailed metadata for one block.
  """
  @spec info(S7.t(), Block.t()) :: {:ok, Block.Info.t()} | {:error, Error.t()}
  def info(client, %Block{} = block) do
    with {:ok, block} <- Block.validate(block, :block_info) do
      API.call(fn -> Connection.block_info(client, block) end, :block_info)
    end
  end

  @spec info(S7.t(), Block.known_type(), 0..0xFFFF) ::
          {:ok, Block.Info.t()} | {:error, Error.t()}
  def info(client, type, number) do
    with {:ok, block} <- Block.normalize(type, number, :block_info) do
      info(client, block)
    end
  end

  @doc """
  Uploads and parses one complete load-memory block image.
  """
  @spec upload(S7.t(), Block.t(), keyword()) ::
          {:ok, Block.Image.t()} | {:error, Error.t()}
  def upload(client, block, opts \\ [])
  def upload(client, %Block{} = block, opts), do: upload_operation(client, block, opts, false)

  @spec upload(S7.t(), Block.known_type(), 0..0xFFFF) ::
          {:ok, Block.Image.t()} | {:error, Error.t()}
  def upload(client, type, number), do: upload(client, type, number, [])

  @spec upload(S7.t(), Block.known_type(), 0..0xFFFF, keyword()) ::
          {:ok, Block.Image.t()} | {:error, Error.t()}
  def upload(client, type, number, opts) do
    with {:ok, block} <- Block.normalize(type, number, :upload_block) do
      upload_operation(client, block, opts, false)
    end
  end

  @doc """
  Uploads one complete load-memory image without parsing it.
  """
  @spec upload_raw(S7.t(), Block.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def upload_raw(client, block, opts \\ [])
  def upload_raw(client, %Block{} = block, opts), do: upload_operation(client, block, opts, true)

  @spec upload_raw(S7.t(), Block.known_type(), 0..0xFFFF) ::
          {:ok, binary()} | {:error, Error.t()}
  def upload_raw(client, type, number), do: upload_raw(client, type, number, [])

  @spec upload_raw(S7.t(), Block.known_type(), 0..0xFFFF, keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def upload_raw(client, type, number, opts) do
    with {:ok, block} <- Block.normalize(type, number, :upload_block) do
      upload_operation(client, block, opts, true)
    end
  end

  @doc """
  Downloads and activates a parsed block image.

  Requires `allow_destructive: true` and `confirm: :download_block`.
  """
  @spec download(S7.t(), Block.Image.t(), keyword()) :: :ok | {:error, Error.t()}
  def download(client, image, opts \\ [])

  def download(client, %Block.Image{} = image, opts),
    do: download_operation(client, image, opts, :download_block, :download_block)

  def download(_client, _image, _opts),
    do: {:error, Error.new(:client, :download_block, :invalid_block_image)}

  @doc """
  Validates, downloads, and activates a raw block image.
  """
  @spec download_raw(S7.t(), Block.t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def download_raw(client, block, raw, opts \\ [])

  def download_raw(client, %Block{} = block, raw, opts),
    do: download_raw_operation(client, block, raw, opts, :download_block, :download_block)

  @spec download_raw(S7.t(), Block.known_type(), 0..0xFFFF, binary()) ::
          :ok | {:error, Error.t()}
  def download_raw(client, type, number, raw), do: download_raw(client, type, number, raw, [])

  @spec download_raw(S7.t(), Block.known_type(), 0..0xFFFF, binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def download_raw(client, type, number, raw, opts) do
    with {:ok, block} <- Block.normalize(type, number, :download_block) do
      download_raw_operation(client, block, raw, opts, :download_block, :download_block)
    end
  end

  @doc """
  Replaces a block through the classic download and activation sequence.

  Requires `allow_destructive: true` and `confirm: :replace_block`.
  """
  @spec replace(S7.t(), Block.Image.t(), keyword()) :: :ok | {:error, Error.t()}
  def replace(client, image, opts \\ [])

  def replace(client, %Block.Image{} = image, opts),
    do: download_operation(client, image, opts, :replace_block, :replace_block)

  def replace(_client, _image, _opts),
    do: {:error, Error.new(:client, :replace_block, :invalid_block_image)}

  @doc """
  Validates and replaces a block from its raw image.
  """
  @spec replace_raw(S7.t(), Block.t(), binary(), keyword()) :: :ok | {:error, Error.t()}
  def replace_raw(client, block, raw, opts \\ [])

  def replace_raw(client, %Block{} = block, raw, opts),
    do: download_raw_operation(client, block, raw, opts, :replace_block, :replace_block)

  @spec replace_raw(S7.t(), Block.known_type(), 0..0xFFFF, binary()) ::
          :ok | {:error, Error.t()}
  def replace_raw(client, type, number, raw), do: replace_raw(client, type, number, raw, [])

  @spec replace_raw(S7.t(), Block.known_type(), 0..0xFFFF, binary(), keyword()) ::
          :ok | {:error, Error.t()}
  def replace_raw(client, type, number, raw, opts) do
    with {:ok, block} <- Block.normalize(type, number, :replace_block) do
      download_raw_operation(client, block, raw, opts, :replace_block, :replace_block)
    end
  end

  @doc """
  Deletes one block.

  Requires `allow_destructive: true` and `confirm: :delete_block`.
  """
  @spec delete(S7.t(), Block.t(), keyword()) :: :ok | {:error, Error.t()}
  def delete(client, block, opts \\ [])

  def delete(client, %Block{} = block, opts) do
    with {:ok, block} <- Block.validate(block, :delete_block),
         {:ok, limits} <- Destructive.validate_options(opts, :delete_block, :delete_block) do
      API.call(fn -> Runtime.delete(client, block, limits, :delete_block) end, :delete_block)
    end
  end

  @spec delete(S7.t(), Block.known_type(), 0..0xFFFF) :: :ok | {:error, Error.t()}
  def delete(client, type, number), do: delete(client, type, number, [])

  @spec delete(S7.t(), Block.known_type(), 0..0xFFFF, keyword()) ::
          :ok | {:error, Error.t()}
  def delete(client, type, number, opts) do
    with {:ok, block} <- Block.normalize(type, number, :delete_block) do
      delete(client, block, opts)
    end
  end

  defp upload_operation(client, block, opts, raw?) do
    with {:ok, block} <- Block.validate(block, :upload_block),
         {:ok, limits} <- Runtime.validate_upload_options(opts, :upload_block) do
      API.call(
        fn -> Runtime.upload(client, block, limits, raw?, :upload_block) end,
        :upload_block
      )
    end
  end

  defp download_raw_operation(client, block, raw, opts, confirmation, operation) do
    with {:ok, image} <- Block.Image.decode(raw, block, operation) do
      download_operation(client, image, opts, confirmation, operation)
    end
  end

  defp download_operation(client, image, opts, confirmation, operation) do
    with {:ok, limits} <- Destructive.validate_options(opts, confirmation, operation),
         {:ok, image} <- Block.Image.decode(image.raw, image.block, operation) do
      API.call(fn -> Runtime.download(client, image, limits, operation) end, operation)
    end
  end
end
