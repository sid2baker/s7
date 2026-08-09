defmodule S7.BlockImageTest do
  use ExUnit.Case, async: true

  alias S7.{Block, BlockImage, Error}
  alias S7.Protocol.PDU
  alias S7.Test.Fixture

  test "parses and retains the complete captured SDB0 load-memory image" do
    raw = captured_image()

    assert {:ok,
            %BlockImage{
              block: %Block{type: :sdb, number: 0},
              header_marker: 0x7070,
              header_byte: 3,
              flags: 2,
              linked?: false,
              standard?: true,
              non_retain?: false,
              language: :sdb,
              language_code: 7,
              load_memory_size: 216,
              security: {:unknown, 0x80000000},
              security_code: 0x80000000,
              sbb_length: 0,
              additional_length: 0,
              local_data_length: 0,
              mc7_size: 144,
              mc7: mc7,
              payload: payload,
              author: "STEP 7 #",
              family: "",
              name: "",
              footer_marker: 0,
              footer_reserved: 0,
              checksum: 0xD1CC,
              footer_prefix: footer_prefix,
              footer_trailer: <<0x31, 0x52, 0x48, 0x14, 0, 0, 0, 0>>,
              raw_header: raw_header,
              raw_footer: raw_footer,
              raw: ^raw
            } = image} = BlockImage.decode(raw, %Block{type: :sdb, number: 0})

    assert byte_size(raw_header) == 36
    assert byte_size(mc7) == 144
    assert byte_size(payload) == 124
    assert byte_size(footer_prefix) == 20
    assert byte_size(raw_footer) == 56
    assert binary_part(raw, 36, 144) == image.mc7
    assert binary_part(raw, 160, 56) == image.raw_footer
    assert %NaiveDateTime{} = image.code_timestamp
    assert %NaiveDateTime{} = image.interface_timestamp
  end

  test "rejects malformed sizes, identity, marker, timestamp, and footer text" do
    raw = captured_image()

    malformed = [
      binary_part(raw, 0, 91),
      replace(raw, 0, <<0, 0>>),
      replace(raw, 8, <<0, 0, 0, 1>>),
      replace(raw, 16, <<0x05, 0x26, 0x5C, 0x01>>),
      replace(raw, 34, <<0xFF, 0xFF>>),
      replace(raw, 180, <<0xFF>>)
    ]

    for image <- malformed do
      assert {:error, %Error{reason: :malformed_block_image}} =
               BlockImage.decode(image, %Block{type: :sdb, number: 0})
    end

    assert {:error,
            %Error{
              reason: :malformed_block_image,
              details: %{expected: {:db, 0}, received: {:sdb, 0}}
            }} = BlockImage.decode(raw, %Block{type: :db, number: 0})

    assert {:error, %Error{reason: :malformed_block_image}} =
             BlockImage.decode(:invalid, %Block{type: :sdb, number: 0})
  end

  defp captured_image do
    assert {:ok, %{data: <<216::unsigned-big-16, 0x00FB::unsigned-big-16, raw::binary>>}, <<>>} =
             Fixture.read!("upload/segment_response.bin") |> PDU.decode()

    raw
  end

  defp replace(binary, offset, replacement) do
    size = byte_size(replacement)
    <<prefix::binary-size(^offset), _old::binary-size(^size), suffix::binary>> = binary
    prefix <> replacement <> suffix
  end
end
