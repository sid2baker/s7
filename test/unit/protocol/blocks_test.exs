defmodule S7.Protocol.BlocksTest do
  use ExUnit.Case, async: true

  alias S7.{Block, BlockEntry, BlockInfo, BlockInventory, Error}
  alias S7.Protocol.{Blocks, PDU, UserData}
  alias S7.Protocol.UserData.{Parameter, Payload}
  alias S7.Test.Fixture

  @limits %{max_bytes: 1_024, max_fragments: 4}

  test "encodes captured block directory requests exactly" do
    assert {:ok, counts, _transaction} = Blocks.start_counts()
    assert encoded(counts, 0x2D00) == Fixture.read!("blocks/counts_request.bin")

    assert {:ok, list, _transaction} = Blocks.start_list(:db, @limits)
    assert encoded(list, 0x3000) == Fixture.read!("blocks/list_db_request.bin")

    assert {:ok, info, _transaction} = Blocks.start_info(%Block{type: :db, number: 1})
    assert encoded(info, 0x4500) == Fixture.read!("blocks/info_db1_request.bin")
  end

  test "decodes the captured block inventory and preserves raw bytes" do
    assert {:ok, _request, transaction} = Blocks.start_counts()
    {pdu, response} = decoded_fixture("blocks/counts_response.bin")

    assert pdu |> PDU.encode() |> IO.iodata_to_binary() ==
             Fixture.read!("blocks/counts_response.bin")

    assert {:ok,
            %BlockInventory{
              counts: %{
                ob: 1,
                fb: 1,
                fc: 0,
                db: 2,
                sdb: 8,
                sfc: 77,
                sfb: 15
              },
              raw: raw
            }} = Blocks.consume(response, transaction, :block_counts)

    assert byte_size(raw) == 28
  end

  test "decodes a captured DB directory" do
    assert {:ok, _request, transaction} = Blocks.start_list(:db, @limits)
    {_pdu, response} = decoded_fixture("blocks/list_db_response.bin")

    assert {:ok,
            [
              %BlockEntry{
                block: %Block{type: :db, number: 1},
                flags: 0x22,
                language: :db,
                raw: <<0, 1, 0x22, 5>>
              },
              %BlockEntry{block: %Block{type: :db, number: 2}}
            ]} = Blocks.consume(response, transaction, :list_blocks)
  end

  test "assembles the captured SFC continuation sequence and reproduces its request" do
    assert {:ok, _request, transaction} = Blocks.start_list(:sfc, @limits)
    {_pdu, first_response} = decoded_fixture("blocks/list_sfc_first_response.bin")

    assert {:continue, continuation, transaction} =
             Blocks.consume(first_response, transaction, :list_blocks)

    assert %UserData{
             parameter: %Parameter{
               method: 0x12,
               type: :request,
               function_group: :blocks,
               subfunction: 2,
               sequence: 1,
               data_unit_reference: 0,
               last_data_unit: 0,
               error_code: 0
             },
             payload: %Payload{return_code: 0x0A, transport_size: 0, data: <<>>}
           } = continuation

    assert encoded(continuation, 0x3300) ==
             Fixture.read!("blocks/list_sfc_continuation_request.bin")

    {_pdu, final_response} = decoded_fixture("blocks/list_sfc_last_response.bin")
    assert {:ok, entries} = Blocks.consume(final_response, transaction, :list_blocks)
    assert Enum.count(entries) == 77
    assert hd(entries).block == %Block{type: :sfc, number: 0}
    assert List.last(entries).block == %Block{type: :sfc, number: 127}
  end

  test "decodes captured detailed block metadata" do
    block = %Block{type: :db, number: 1}
    assert {:ok, _request, transaction} = Blocks.start_info(block)
    {_pdu, response} = decoded_fixture("blocks/info_db1_response.bin")

    assert {:ok,
            %BlockInfo{
              block: ^block,
              language: :db,
              language_code: 5,
              flags: 1,
              linked?: true,
              standard?: false,
              non_retain?: false,
              load_memory_size: 102,
              security: :know_how_protected,
              security_code: 3,
              code_timestamp: ~N[2015-12-15 22:59:37.264],
              interface_timestamp: ~N[1996-08-09 08:21:46.960],
              sbb_length: 20,
              additional_length: 0,
              local_data_length: 0,
              mc7_size: 10,
              author: "SIMATIC",
              family: "IEC_TC",
              name: "CTU",
              version: {1, 0},
              checksum: 0x798C,
              raw_header: <<1, 0, 0, 74, 0x22, 0, "pp", 1>>,
              reserved: <<0::64>>,
              raw: raw
            }} = Blocks.consume(response, transaction, :block_info)

    assert byte_size(raw) == 78
  end

  test "preserves unknown directory codes" do
    inventory =
      <<0x7A7B::16, 9::16, 0x3045::16, 1::16, 0x3043::16, 0::16, 0x3041::16, 2::16, 0x3042::16,
        8::16, 0x3044::16, 77::16, 0x3046::16, 15::16>>

    assert {:ok, %BlockInventory{counts: %{{:unknown, 0x7A7B} => 9}}} =
             Blocks.decode_inventory(inventory)

    assert {:ok, [%BlockEntry{language: {:unknown, 0x7A}, language_code: 0x7A}]} =
             Blocks.decode_entries(:db, <<1::16, 0, 0x7A>>)
  end

  test "rejects malformed directory geometry and direct invalid requests" do
    assert {:error, %Error{reason: :malformed_response}} = Blocks.decode_inventory(<<>>)

    duplicate_inventory =
      IO.iodata_to_binary(for _index <- 1..7, do: <<0x3041::16, 1::16>>)

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.decode_inventory(duplicate_inventory)

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.decode_entries(:db, <<0, 1, 2>>)

    assert {:error, %Error{reason: :invalid_block}} =
             Blocks.decode_entries(:invalid, <<>>)

    assert {:error, %Error{reason: :invalid_block}} =
             Blocks.start_info(%Block{type: :invalid, number: 1})

    assert {:error, %Error{reason: :invalid_block_request}} =
             Blocks.start_info(:invalid)

    assert {:error, %Error{reason: :invalid_block_request}} =
             Blocks.start_list(:db, %{})
  end

  test "rejects malformed block information headers, identities, and timestamps" do
    raw = info_payload()

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.decode_info(%Block{type: :db, number: 2}, raw)

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.decode_info(%Block{type: :db, number: 1}, replace_byte(raw, 3, 73))

    <<prefix::binary-size(22), _milliseconds::32, suffix::binary>> = raw
    invalid_time = <<prefix::binary, 86_400_000::32, suffix::binary>>

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.decode_info(%Block{type: :db, number: 1}, invalid_time)

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.decode_info(%Block{type: :db, number: 1}, binary_part(raw, 0, 77))
  end

  test "rejects invalid fragment envelopes, identity changes, and resource exhaustion" do
    assert {:ok, _request, transaction} =
             Blocks.start_list(:db, %{max_bytes: 8, max_fragments: 2})

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.consume(response(<<>>, transport_size: 4), transaction, :list_blocks)

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.consume(response(<<>>, extension?: false), transaction, :list_blocks)

    assert {:continue, _request, transaction} =
             Blocks.consume(
               response(<<0, 1, 0, 5>>, more?: true, data_unit_reference: 7),
               transaction,
               :list_blocks
             )

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.consume(
               response(<<0, 2, 0, 5>>, data_unit_reference: 8),
               transaction,
               :list_blocks
             )

    assert {:error, %Error{reason: :too_many_userdata_fragments}} =
             Blocks.consume(
               response(<<>>, more?: true),
               %{transaction | fragment_count: 1},
               :list_blocks
             )

    assert {:error, %Error{reason: :userdata_too_large}} =
             Blocks.consume(response(<<0::72>>), transaction, :list_blocks)

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.consume(:invalid, transaction, :list_blocks)
  end

  test "rejects continuations for fixed-size block services" do
    assert {:ok, _request, counts_transaction} = Blocks.start_counts()

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.consume(response(<<>>, more?: true), counts_transaction, :block_counts)

    assert {:ok, _request, info_transaction} =
             Blocks.start_info(%Block{type: :db, number: 1})

    assert {:error, %Error{reason: :malformed_response}} =
             Blocks.consume(response(<<>>, more?: true), info_transaction, :block_info)
  end

  defp decoded_fixture(path) do
    assert {:ok, pdu, <<>>} = path |> Fixture.read!() |> PDU.decode()
    assert {:ok, response} = UserData.from_pdu(pdu)
    {pdu, response}
  end

  defp encoded(message, reference) do
    assert {:ok, pdu} = UserData.to_pdu(message, reference)
    pdu |> PDU.encode() |> IO.iodata_to_binary()
  end

  defp info_payload do
    {_pdu, response} = decoded_fixture("blocks/info_db1_response.bin")
    response.payload.data
  end

  defp replace_byte(binary, index, value) do
    <<prefix::binary-size(^index), _old, suffix::binary>> = binary
    <<prefix::binary, value, suffix::binary>>
  end

  defp response(data, opts \\ []) do
    extension? = Keyword.get(opts, :extension?, true)

    %UserData{
      parameter: %Parameter{
        method: 0x12,
        type: :response,
        function_group: :blocks,
        subfunction: 2,
        sequence: 1,
        data_unit_reference: if(extension?, do: Keyword.get(opts, :data_unit_reference, 7)),
        last_data_unit: if(extension?, do: if(Keyword.get(opts, :more?, false), do: 1, else: 0)),
        error_code: if(extension?, do: 0)
      },
      payload: %Payload{
        transport_size: Keyword.get(opts, :transport_size, 9),
        data: data
      }
    }
  end
end
