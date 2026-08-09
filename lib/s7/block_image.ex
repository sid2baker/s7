defmodule S7.BlockImage do
  @moduledoc """
  A parsed classic load-memory block image with all original bytes retained.

  The declared MC7 range starts immediately after the 36-byte header. Classic
  images may include the footer prefix in that range, so `mc7` and `raw_footer`
  can overlap. `payload` is the non-overlapping region between the header and
  the 56-byte footer.
  """

  import Bitwise

  alias S7.{Block, Error}

  @header_size 36
  @footer_size 56
  @header_marker 0x7070

  @enforce_keys [
    :block,
    :header_marker,
    :header_byte,
    :flags,
    :language,
    :language_code,
    :load_memory_size,
    :security,
    :security_code,
    :code_timestamp,
    :interface_timestamp,
    :sbb_length,
    :additional_length,
    :local_data_length,
    :mc7_size,
    :mc7,
    :payload,
    :author,
    :family,
    :name,
    :footer_marker,
    :footer_reserved,
    :checksum,
    :footer_prefix,
    :footer_trailer,
    :raw_header,
    :raw_footer,
    :raw
  ]
  defstruct [
    :block,
    :header_marker,
    :header_byte,
    :flags,
    :linked?,
    :standard?,
    :non_retain?,
    :language,
    :language_code,
    :load_memory_size,
    :security,
    :security_code,
    :code_timestamp,
    :interface_timestamp,
    :sbb_length,
    :additional_length,
    :local_data_length,
    :mc7_size,
    :mc7,
    :payload,
    :author,
    :family,
    :name,
    :footer_marker,
    :footer_reserved,
    :checksum,
    :footer_prefix,
    :footer_trailer,
    :raw_header,
    :raw_footer,
    :raw
  ]

  @type security :: :none | :know_how_protected | {:unknown, 0..0xFFFFFFFF}

  @type t :: %__MODULE__{
          block: Block.t(),
          header_marker: 0..0xFFFF,
          header_byte: byte(),
          flags: byte(),
          linked?: boolean(),
          standard?: boolean(),
          non_retain?: boolean(),
          language: Block.language(),
          language_code: byte(),
          load_memory_size: non_neg_integer(),
          security: security(),
          security_code: 0..0xFFFFFFFF,
          code_timestamp: NaiveDateTime.t(),
          interface_timestamp: NaiveDateTime.t(),
          sbb_length: non_neg_integer(),
          additional_length: non_neg_integer(),
          local_data_length: non_neg_integer(),
          mc7_size: non_neg_integer(),
          mc7: binary(),
          payload: binary(),
          author: String.t(),
          family: String.t(),
          name: String.t(),
          footer_marker: byte(),
          footer_reserved: byte(),
          checksum: 0..0xFFFF,
          footer_prefix: binary(),
          footer_trailer: binary(),
          raw_header: binary(),
          raw_footer: binary(),
          raw: binary()
        }

  @doc """
  Decodes and validates a complete load-memory image for the requested block.
  """
  @spec decode(binary(), Block.t(), atom()) :: {:ok, t()} | {:error, Error.t()}
  def decode(raw, block, operation \\ :decode_block_image)

  def decode(raw, %Block{} = requested, operation)
      when is_binary(raw) and byte_size(raw) >= @header_size + @footer_size do
    <<raw_header::binary-size(@header_size), _rest::binary>> = raw

    <<header_marker::unsigned-big-16, header_byte, flags, language_code, subtype_code,
      number::unsigned-big-16, load_memory_size::unsigned-big-32, security_code::unsigned-big-32,
      code_milliseconds::unsigned-big-32, code_days::unsigned-big-16,
      interface_milliseconds::unsigned-big-32, interface_days::unsigned-big-16,
      sbb_length::unsigned-big-16, additional_length::unsigned-big-16,
      local_data_length::unsigned-big-16, mc7_size::unsigned-big-16>> = raw_header

    subtype = Block.decode_subtype(subtype_code)

    with :ok <- validate_header_marker(header_marker, operation),
         :ok <- validate_identity(requested, subtype, number, operation),
         :ok <- validate_load_size(load_memory_size, raw, operation),
         :ok <- validate_mc7_size(mc7_size, raw, operation),
         {:ok, code_timestamp} <-
           Block.decode_timestamp(
             code_milliseconds,
             code_days,
             :code_timestamp,
             operation,
             :malformed_block_image
           ),
         {:ok, interface_timestamp} <-
           Block.decode_timestamp(
             interface_milliseconds,
             interface_days,
             :interface_timestamp,
             operation,
             :malformed_block_image
           ),
         {:ok, footer} <- decode_footer(raw, operation) do
      payload_size = byte_size(raw) - @header_size - @footer_size
      payload = binary_part(raw, @header_size, payload_size)
      mc7 = binary_part(raw, @header_size, mc7_size)

      {:ok,
       struct!(__MODULE__,
         block: %Block{type: subtype, number: number},
         header_marker: header_marker,
         header_byte: header_byte,
         flags: flags,
         linked?: (flags &&& 0x01) != 0,
         standard?: (flags &&& 0x02) != 0,
         non_retain?: (flags &&& 0x08) != 0,
         language: Block.decode_language(language_code),
         language_code: language_code,
         load_memory_size: load_memory_size,
         security: decode_security(security_code),
         security_code: security_code,
         code_timestamp: code_timestamp,
         interface_timestamp: interface_timestamp,
         sbb_length: sbb_length,
         additional_length: additional_length,
         local_data_length: local_data_length,
         mc7_size: mc7_size,
         mc7: mc7,
         payload: payload,
         author: footer.author,
         family: footer.family,
         name: footer.name,
         footer_marker: footer.marker,
         footer_reserved: footer.reserved,
         checksum: footer.checksum,
         footer_prefix: footer.prefix,
         footer_trailer: footer.trailer,
         raw_header: raw_header,
         raw_footer: footer.raw,
         raw: raw
       )}
    end
  end

  def decode(raw, %Block{}, operation) when is_binary(raw) do
    malformed(operation, %{
      minimum_size: @header_size + @footer_size,
      received_size: byte_size(raw)
    })
  end

  def decode(_raw, _block, operation), do: malformed(operation, %{})

  defp decode_footer(raw, operation) do
    offset = byte_size(raw) - @footer_size
    footer = binary_part(raw, offset, @footer_size)

    <<prefix::binary-size(20), author::binary-size(8), family::binary-size(8),
      name::binary-size(8), marker, reserved, checksum::unsigned-big-16, trailer::binary-size(8)>> =
      footer

    with {:ok, author} <- decode_text(author, :author, operation),
         {:ok, family} <- decode_text(family, :family, operation),
         {:ok, name} <- decode_text(name, :name, operation) do
      {:ok,
       %{
         prefix: prefix,
         author: author,
         family: family,
         name: name,
         marker: marker,
         reserved: reserved,
         checksum: checksum,
         trailer: trailer,
         raw: footer
       }}
    end
  end

  defp validate_header_marker(@header_marker, _operation), do: :ok

  defp validate_header_marker(marker, operation),
    do: malformed(operation, %{header_marker: marker})

  defp validate_identity(%Block{type: type, number: number}, type, number, _operation), do: :ok

  defp validate_identity(expected, type, number, operation),
    do:
      malformed(operation, %{
        expected: {expected.type, expected.number},
        received: {type, number}
      })

  defp validate_load_size(size, raw, _operation) when size == byte_size(raw), do: :ok

  defp validate_load_size(size, raw, operation),
    do: malformed(operation, %{declared_size: size, received_size: byte_size(raw)})

  defp validate_mc7_size(size, raw, _operation) when @header_size + size <= byte_size(raw),
    do: :ok

  defp validate_mc7_size(size, raw, operation),
    do: malformed(operation, %{mc7_size: size, received_size: byte_size(raw)})

  defp decode_text(value, field, operation) do
    value = trim_padding(value)

    if String.valid?(value) do
      {:ok, value}
    else
      malformed(operation, %{field: field, encoding: :invalid_utf8})
    end
  end

  defp trim_padding(<<>>), do: <<>>

  defp trim_padding(value) do
    if :binary.last(value) in [0, 0x20] do
      value |> binary_part(0, byte_size(value) - 1) |> trim_padding()
    else
      value
    end
  end

  defp decode_security(0), do: :none
  defp decode_security(3), do: :know_how_protected
  defp decode_security(code), do: {:unknown, code}

  defp malformed(operation, details),
    do: {:error, Error.new(:s7, operation, :malformed_block_image, details: details)}
end
