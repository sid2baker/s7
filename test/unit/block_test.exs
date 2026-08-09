defmodule S7.BlockTest do
  use ExUnit.Case, async: true

  alias S7.{Block, Error}

  test "normalizes every supported block identity" do
    for {type, code} <- [
          ob: 0x3038,
          cmod: 0x3039,
          db: 0x3041,
          sdb: 0x3042,
          fc: 0x3043,
          sfc: 0x3044,
          fb: 0x3045,
          sfb: 0x3046
        ] do
      assert {:ok, %Block{type: ^type, number: 65_535}} =
               Block.normalize(type, 65_535, :block_info)

      assert Block.encode_type(type) == <<code::16>>
      assert Block.decode_type(code) == type
    end
  end

  test "decoders preserve unknown type, subtype, and language codes" do
    assert Block.decode_type(0x7A7B) == {:unknown, 0x7A7B}
    assert Block.decode_subtype(0x7A) == {:unknown, 0x7A}
    assert Block.decode_language(0x7A) == {:unknown, 0x7A}

    assert Block.decode_subtype(0x08) == :ob
    assert Block.decode_subtype(0x0F) == :sfb
    assert Block.decode_language(0x04) == :scl
    assert Block.decode_language(0x29) == :encrypted
  end

  test "rejects invalid block identities without raising" do
    assert {:error,
            %Error{
              layer: :client,
              operation: :block_info,
              reason: :invalid_block,
              details: %{field: :type, value: :invalid}
            }} = Block.normalize(:invalid, 1, :block_info)

    assert {:error, %Error{reason: :invalid_block, details: %{field: :number}}} =
             Block.normalize(:db, 65_536, :block_info)

    assert {:error, %Error{reason: :invalid_block, details: %{field: :block}}} =
             Block.validate(:db1, :block_info)
  end

  test "validates bounded list options" do
    assert {:ok, %{max_bytes: 1_048_576, max_fragments: 64}} =
             Block.validate_list_options([], :list_blocks)

    assert {:ok, %{max_bytes: 4, max_fragments: 2}} =
             Block.validate_list_options([max_bytes: 4, max_fragments: 2], :list_blocks)

    for opts <- [[max_bytes: 0], [max_bytes: 16_777_217], [max_fragments: 0]] do
      assert {:error, %Error{reason: :invalid_option}} =
               Block.validate_list_options(opts, :list_blocks)
    end

    assert {:error, %Error{reason: :invalid_option, details: %{option: :unknown, value: true}}} =
             Block.validate_list_options([unknown: true], :list_blocks)

    assert {:error, %Error{reason: :invalid_options}} =
             Block.validate_list_options([:not_a_pair], :list_blocks)

    assert {:error, %Error{reason: :invalid_options}} =
             Block.validate_list_options(:invalid, :list_blocks)
  end
end
