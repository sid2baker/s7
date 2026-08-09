defmodule S7.BlockInfo do
  @moduledoc "Decoded classic block metadata with its complete raw response retained."

  alias S7.Block

  @enforce_keys [
    :block,
    :language,
    :language_code,
    :flags,
    :load_memory_size,
    :security,
    :security_code,
    :code_timestamp,
    :interface_timestamp,
    :sbb_length,
    :additional_length,
    :local_data_length,
    :mc7_size,
    :author,
    :family,
    :name,
    :version,
    :checksum,
    :raw_header,
    :reserved,
    :raw
  ]
  defstruct [
    :block,
    :language,
    :language_code,
    :flags,
    :linked?,
    :standard?,
    :non_retain?,
    :load_memory_size,
    :security,
    :security_code,
    :code_timestamp,
    :interface_timestamp,
    :sbb_length,
    :additional_length,
    :local_data_length,
    :mc7_size,
    :author,
    :family,
    :name,
    :version,
    :checksum,
    :raw_header,
    :reserved,
    :raw
  ]

  @type security :: :none | :know_how_protected | {:unknown, 0..0xFFFFFFFF}

  @type t :: %__MODULE__{
          block: Block.t(),
          language: Block.language(),
          language_code: byte(),
          flags: byte(),
          linked?: boolean(),
          standard?: boolean(),
          non_retain?: boolean(),
          load_memory_size: non_neg_integer(),
          security: security(),
          security_code: 0..0xFFFFFFFF,
          code_timestamp: NaiveDateTime.t(),
          interface_timestamp: NaiveDateTime.t(),
          sbb_length: non_neg_integer(),
          additional_length: non_neg_integer(),
          local_data_length: non_neg_integer(),
          mc7_size: non_neg_integer(),
          author: String.t(),
          family: String.t(),
          name: String.t(),
          version: {0..15, 0..15},
          checksum: 0..0xFFFF,
          raw_header: binary(),
          reserved: binary(),
          raw: binary()
        }
end
