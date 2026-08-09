defmodule S7.Transport.TPKT do
  @moduledoc """
  RFC 1006 TPKT framing.

  `decode/1` consumes at most one frame and leaves concatenated TCP data in the
  returned remainder. It reports the exact number of bytes required when a
  header or payload is incomplete.
  """

  @version 3
  @header_size 4
  @minimum_packet_size 7
  @maximum_packet_size 0xFFFF

  @enforce_keys [:payload]
  defstruct [:payload]

  @type t :: %__MODULE__{payload: binary()}
  @type decode_error ::
          :invalid_tpkt
          | :invalid_version
          | :invalid_reserved_byte
          | :invalid_length
          | :oversized_length

  @doc """
  Encodes a TPKT frame as iodata.
  """
  @spec encode(t()) :: iodata()
  def encode(%__MODULE__{payload: payload}) when is_binary(payload) do
    length = @header_size + byte_size(payload)

    if length in @minimum_packet_size..@maximum_packet_size do
      [<<@version, 0, length::unsigned-big-16>>, payload]
    else
      raise ArgumentError, "TPKT packet length must be between 7 and 65535 bytes"
    end
  end

  def encode(_packet), do: raise(ArgumentError, "expected an S7.Transport.TPKT struct")

  @doc """
  Decodes one TPKT frame.

  `:max_size` can impose a lower application limit than RFC 1006's 65,535-byte
  maximum.
  """
  @spec decode(binary(), keyword()) ::
          {:ok, t(), binary()} | {:more, pos_integer()} | {:error, decode_error()}
  def decode(binary, opts \\ [])

  def decode(binary, opts) when is_binary(binary) and is_list(opts) do
    max_size = Keyword.get(opts, :max_size, @maximum_packet_size)

    cond do
      not valid_max_size?(max_size) ->
        {:error, :invalid_tpkt}

      byte_size(binary) < @header_size ->
        {:more, @header_size - byte_size(binary)}

      true ->
        decode_header(binary, max_size)
    end
  end

  def decode(_binary, _opts), do: {:error, :invalid_tpkt}

  defp decode_header(<<version, reserved, length::unsigned-big-16, rest::binary>>, max_size) do
    cond do
      version != @version ->
        {:error, :invalid_version}

      reserved != 0 ->
        {:error, :invalid_reserved_byte}

      length < @minimum_packet_size ->
        {:error, :invalid_length}

      length > max_size ->
        {:error, :oversized_length}

      byte_size(rest) < length - @header_size ->
        {:more, length - @header_size - byte_size(rest)}

      true ->
        payload_size = length - @header_size
        <<payload::binary-size(^payload_size), remaining::binary>> = rest
        {:ok, %__MODULE__{payload: payload}, remaining}
    end
  end

  defp valid_max_size?(max_size) do
    is_integer(max_size) and max_size in @minimum_packet_size..@maximum_packet_size
  end
end
