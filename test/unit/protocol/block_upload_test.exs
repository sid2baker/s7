defmodule S7.Protocol.BlockUploadTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias S7.{Block, Error}
  alias S7.Protocol.{BlockUpload, PDU}
  alias S7.Test.Fixture

  @limits %{max_bytes: 1024, max_fragments: 4, timeout: 1_000, step_timeout: nil}

  test "round-trips the captured start-upload exchange" do
    block = %Block{type: :sdb, number: 0}
    assert {:ok, request, transaction} = BlockUpload.start_request(block, @limits, :upload_block)

    request = put_in(request.header.pdu_reference, 0x0800)
    assert encoded(request) == Fixture.read!("upload/start_sdb0_request.bin")

    assert {:ok, response, <<>>} =
             Fixture.read!("upload/start_sdb0_response.bin") |> PDU.decode()

    assert {:ok, transaction} = BlockUpload.consume_start(response, transaction)
    assert transaction.upload_id == 7
    assert transaction.advertised_size == 216
    assert BlockUpload.validate_advertised_size(transaction) == :ok
    assert encoded(response) == Fixture.read!("upload/start_sdb0_response.bin")
  end

  test "round-trips the captured upload segment and end exchange" do
    transaction = started_transaction()
    assert {:ok, request} = BlockUpload.upload_request(transaction)
    request = put_in(request.header.pdu_reference, 0x0900)
    assert encoded(request) == Fixture.read!("upload/segment_request.bin")

    assert {:ok, response, <<>>} = Fixture.read!("upload/segment_response.bin") |> PDU.decode()

    assert {:complete, raw, transaction} = BlockUpload.consume_segment(response, transaction)
    assert byte_size(raw) == 216
    assert transaction.fragment_count == 1
    assert transaction.size == 216
    assert encoded(response) == Fixture.read!("upload/segment_response.bin")

    assert {:ok, request} = BlockUpload.end_request(transaction)
    request = put_in(request.header.pdu_reference, 0x0A00)
    assert encoded(request) == Fixture.read!("upload/end_request.bin")

    assert {:ok, response, <<>>} = Fixture.read!("upload/end_response.bin") |> PDU.decode()
    assert BlockUpload.consume_end(response, transaction) == :ok
    assert encoded(response) == Fixture.read!("upload/end_response.bin")
  end

  test "assembles multiple bounded segments in order" do
    transaction = %{started_transaction() | advertised_size: 6}
    first = segment_response("abc", true)
    second = segment_response("def", false)

    assert {:continue, transaction} = BlockUpload.consume_segment(first, transaction)

    assert {:complete, "abcdef", transaction} =
             BlockUpload.consume_segment(second, transaction)

    assert transaction.fragment_count == 2
  end

  test "maps captured and established PLC header errors" do
    block = %Block{type: :ob, number: 0}

    assert {:ok, _request, transaction} =
             BlockUpload.start_request(block, @limits, :upload_block)

    assert {:ok, response, <<>>} =
             Fixture.read!("upload/start_ob0_error_response.bin") |> PDU.decode()

    assert {:error, %Error{reason: :invalid_block, code: 0xD20C} = error} =
             BlockUpload.consume_start(response, transaction)

    assert BlockUpload.initial_rejection?(error)

    for {code, reason} <- [
          {0xD241, :access_denied},
          {0xD20E, :object_not_found},
          {0xD210, :invalid_block},
          {0xD2A1, :resource_busy},
          {0x1234, :plc_error}
        ] do
      response = PDU.new(:ack, 1, <<>>, <<>>, error_class: code >>> 8, error_code: code &&& 0xFF)

      assert {:error, %Error{reason: ^reason, code: ^code}} =
               BlockUpload.consume_start(response, transaction)
    end
  end

  test "rejects malformed start, segment, and end responses" do
    transaction = started_transaction()

    malformed_start = [
      PDU.new(:ack_data, 1, <<0x1D, 0, 0::16, 0::32, 1, "1">>),
      PDU.new(:ack_data, 1, <<0x1D, 1, 0::16, 7::32, 1, "1">>),
      PDU.new(:ack_data, 1, <<0x1D, 0, 0::16, 7::32, 2, "x1">>),
      PDU.new(:ack_data, 1, <<0x1D, 0, 0::16, 7::32, 1, "1">>, <<0>>),
      PDU.new(:job, 1, <<0x1D, 0, 0::16, 7::32, 1, "1">>)
    ]

    for response <- malformed_start do
      assert {:error, %Error{reason: :malformed_response}} =
               BlockUpload.consume_start(response, fresh_transaction())
    end

    malformed_segments = [
      PDU.new(:ack_data, 1, <<0x1E, 4>>, <<1::16, 0x00FB::16, "a">>),
      PDU.new(:ack_data, 1, <<0x1E, 0>>, <<2::16, 0x00FB::16, "a">>),
      PDU.new(:ack_data, 1, <<0x1E, 0>>, <<1::16, 0x00FA::16, "a">>),
      PDU.new(:ack_data, 1, <<0x1E>>, <<1::16, 0x00FB::16, "a">>)
    ]

    for response <- malformed_segments do
      assert {:error, %Error{reason: :malformed_response}} =
               BlockUpload.consume_segment(response, %{transaction | advertised_size: 1})
    end

    assert {:error, %Error{reason: :plc_error, code: 2}} =
             BlockUpload.consume_segment(
               PDU.new(:ack_data, 1, <<0x1E, 2>>, <<1::16, 0x00FB::16, "a">>),
               %{transaction | advertised_size: 1}
             )

    assert {:error, %Error{reason: :malformed_response}} =
             BlockUpload.consume_end(PDU.new(:ack_data, 1, <<0x1F, 0>>), transaction)
  end

  test "enforces advertised, aggregate, and fragment bounds" do
    too_large = %{started_transaction() | advertised_size: 5, max_bytes: 4}

    assert {:error, %Error{reason: :block_upload_too_large, details: %{limit: 4}} = error} =
             BlockUpload.validate_advertised_size(too_large)

    assert BlockUpload.local_limit_error?(error)

    transaction = %{started_transaction() | advertised_size: 6, max_bytes: 4}

    assert {:error, %Error{reason: :block_upload_too_large}} =
             BlockUpload.consume_segment(segment_response("abcde", false), transaction)

    transaction = %{started_transaction() | advertised_size: 6, max_fragments: 1}

    assert {:error, %Error{reason: :too_many_upload_fragments} = error} =
             BlockUpload.consume_segment(segment_response("abc", true), transaction)

    assert BlockUpload.local_limit_error?(error)

    assert {:error, %Error{reason: :malformed_response}} =
             BlockUpload.consume_segment(
               segment_response("abcdefg", false),
               %{started_transaction() | advertised_size: 6}
             )

    assert {:error, %Error{reason: :malformed_response}} =
             BlockUpload.consume_segment(
               segment_response("abcdef", true),
               %{started_transaction() | advertised_size: 6}
             )

    assert {:error, %Error{reason: :malformed_response}} =
             BlockUpload.consume_segment(
               segment_response("abc", false),
               %{started_transaction() | advertised_size: 6}
             )
  end

  test "validates public upload options without reserving a transaction" do
    assert {:ok, %{max_bytes: 10, max_fragments: 2, timeout: 100, step_timeout: 50}} =
             BlockUpload.validate_options(
               [max_bytes: 10, max_fragments: 2, timeout: 100, step_timeout: 50],
               :upload_block
             )

    for options <- [
          :invalid,
          [:invalid],
          [unknown: 1],
          [max_bytes: 0],
          [max_fragments: 0],
          [timeout: 0],
          [step_timeout: :infinity]
        ] do
      assert {:error, %Error{layer: :client, reason: reason}} =
               BlockUpload.validate_options(options, :upload_block)

      assert reason in [:invalid_options, :invalid_option]
    end
  end

  defp fresh_transaction do
    block = %Block{type: :sdb, number: 0}
    {:ok, _request, transaction} = BlockUpload.start_request(block, @limits, :upload_block)
    transaction
  end

  defp started_transaction do
    assert {:ok, response, <<>>} =
             Fixture.read!("upload/start_sdb0_response.bin") |> PDU.decode()

    assert {:ok, transaction} = BlockUpload.consume_start(response, fresh_transaction())
    transaction
  end

  defp segment_response(chunk, more?) do
    status = if more?, do: 1, else: 0

    PDU.new(
      :ack_data,
      1,
      <<0x1E, status>>,
      <<byte_size(chunk)::unsigned-big-16, 0x00FB::unsigned-big-16, chunk::binary>>
    )
  end

  defp encoded(pdu), do: pdu |> PDU.encode() |> IO.iodata_to_binary()
end
