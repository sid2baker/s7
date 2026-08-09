defmodule S7.Protocol.BlockDownloadTest do
  use ExUnit.Case, async: true

  alias S7.{Block, BlockImage, Error}
  alias S7.Protocol.{BlockDownload, PDU}
  alias S7.Test.Fixture

  test "encodes and decodes the captured Request Download exchange" do
    image = captured_image()
    assert {:ok, request, transaction} = BlockDownload.start_request(image, :download_block)

    request = put_in(request.header.pdu_reference, 0x8300)
    assert encode(request) == Fixture.read!("download/request_db1.bin")

    assert {:ok,
            %{
              block: %Block{type: :db, number: 1},
              load_memory_size: 216,
              mc7_size: 88
            }} =
             fixture_pdu("download/request_db1.bin") |> BlockDownload.decode_start_request(:test)

    response = fixture_pdu("download/request_response.bin")
    assert {:ok, %{stage: :download}} = BlockDownload.consume_start(response, transaction)
  end

  test "answers the captured PLC pull and Download Ended jobs exactly" do
    image = captured_image()
    {:ok, _request, transaction} = BlockDownload.start_request(image, :download_block)

    {:ok, transaction} =
      BlockDownload.consume_start(fixture_pdu("download/request_response.bin"), transaction)

    block_request = fixture_pdu("download/block_request.bin")

    assert {:ok, block_response, transaction} =
             BlockDownload.consume_download_job(block_request, transaction, 480)

    assert encode(block_response) == Fixture.read!("download/block_response.bin")
    assert transaction.stage == :download_ended
    assert transaction.offset == 216
    assert transaction.fragment_count == 1

    assert {:ok, %{more?: false, data: raw}} =
             BlockDownload.decode_download_response(block_response, :test)

    assert raw == image.raw

    ended_request = fixture_pdu("download/ended_request.bin")
    block = image.block

    assert {:ok, ended_response, transaction, %{error_code: 0, block: ^block}} =
             BlockDownload.consume_end_job(ended_request, transaction)

    assert transaction.stage == :complete
    assert encode(ended_response) == Fixture.read!("download/ended_response.bin")
    assert BlockDownload.decode_end_response(ended_response, :test) == :ok
  end

  test "splits responses against negotiated PDU size and rejects repeated jobs" do
    image = captured_image()
    transaction = started_transaction(image)

    first = download_job(1, image.block)

    assert {:ok, response, transaction} =
             BlockDownload.consume_download_job(first, transaction, 100)

    assert {:ok, %{more?: true, data: first_data}} =
             BlockDownload.decode_download_response(response, :test)

    assert byte_size(first_data) == 82

    assert {:error, %Error{reason: :malformed_response, details: %{duplicate_pdu_reference: 1}}} =
             BlockDownload.consume_download_job(first, transaction, 100)

    second = download_job(2, image.block)

    assert {:ok, response, transaction} =
             BlockDownload.consume_download_job(second, transaction, 100)

    assert {:ok, %{more?: true, data: second_data}} =
             BlockDownload.decode_download_response(response, :test)

    assert byte_size(second_data) == 82

    third = download_job(3, image.block)

    assert {:ok, response, transaction} =
             BlockDownload.consume_download_job(third, transaction, 100)

    assert {:ok, %{more?: false, data: third_data}} =
             BlockDownload.decode_download_response(response, :test)

    assert byte_size(third_data) == 52
    assert transaction.stage == :download_ended
  end

  test "rejects malformed direction, identity, sizes, sequence, and data" do
    image = captured_image()
    transaction = started_transaction(image)

    wrong_block = download_job(1, %Block{type: :db, number: 2})

    assert {:error, %Error{reason: :malformed_response, details: %{block_identity: :changed}}} =
             BlockDownload.consume_download_job(wrong_block, transaction, 480)

    assert {:error, %Error{reason: :pdu_too_small}} =
             BlockDownload.consume_download_job(download_job(1, image.block), transaction, 18)

    malformed = PDU.new(:ack_data, 1, <<0x1B, 0>>, <<0, 1, 0, 0>>)

    assert {:error, %Error{reason: :malformed_response}} =
             BlockDownload.decode_download_response(malformed, :test)

    ended = fixture_pdu("download/ended_request.bin")

    assert {:error, %Error{reason: :malformed_response, details: %{stage: :invalid}}} =
             BlockDownload.consume_end_job(ended, transaction)

    malformed_start = put_in(fixture_pdu("download/request_db1.bin").data, <<0>>)

    assert {:error, %Error{reason: :malformed_response}} =
             BlockDownload.decode_start_request(malformed_start, :test)
  end

  test "retains a PLC Download Ended error for a complete rejection" do
    image = captured_image()
    transaction = %{started_transaction(image) | stage: :download_ended, offset: 216}
    request = download_end_job(4, image.block, 0xD241)

    assert {:ok, _response, _transaction, end_request} =
             BlockDownload.consume_end_job(request, transaction)

    assert {:error, %Error{reason: :block_download_rejected, code: 0xD241}} =
             BlockDownload.end_error(end_request, :download_block)
  end

  test "bounds six-digit image and MC7 lengths" do
    image = captured_image()
    oversized = %{image | raw: :binary.copy(<<0>>, 1_000_000)}

    assert {:error, %Error{reason: :block_image_too_large}} =
             BlockDownload.start_request(oversized, :download_block)

    oversized_mc7 = %{image | mc7_size: 1_000_000}

    assert {:error, %Error{reason: :block_image_too_large}} =
             BlockDownload.start_request(oversized_mc7, :download_block)

    assert {:error, %Error{reason: :invalid_block_image}} =
             BlockDownload.start_request(:not_an_image, :download_block)
  end

  test "rejects invalid declared sizes and a malformed start acknowledgement" do
    request = fixture_pdu("download/request_db1.bin")

    invalid_sizes =
      update_in(request.parameters, fn parameters ->
        <<prefix::binary-size(20), _sizes::binary-size(12)>> = parameters
        prefix <> "000010000011"
      end)

    assert {:error, %Error{reason: :malformed_response}} =
             BlockDownload.decode_start_request(invalid_sizes, :test)

    image = captured_image()
    {:ok, _request, transaction} = BlockDownload.start_request(image, :download_block)
    malformed = PDU.new(:ack_data, 1, <<0x1A, 0>>)

    assert {:error, %Error{reason: :malformed_response}} =
             BlockDownload.consume_start(malformed, transaction)
  end

  defp captured_image do
    response = fixture_pdu("download/block_response.bin")
    assert {:ok, %{data: raw}} = BlockDownload.decode_download_response(response, :test)
    assert {:ok, image} = BlockImage.decode(raw, %Block{type: :db, number: 1})
    image
  end

  defp started_transaction(image) do
    {:ok, _request, transaction} = BlockDownload.start_request(image, :download_block)

    {:ok, transaction} =
      BlockDownload.consume_start(fixture_pdu("download/request_response.bin"), transaction)

    transaction
  end

  defp download_job(reference, block) do
    filename = Block.encode_filename(block, :passive)
    PDU.new(:job, reference, <<0x1B, 0, 0::16, 0::32, 9, filename::binary>>)
  end

  defp download_end_job(reference, block, error_code) do
    filename = Block.encode_filename(block, :passive)
    PDU.new(:job, reference, <<0x1C, 0, error_code::16, 0::32, 9, filename::binary>>)
  end

  defp fixture_pdu(path) do
    assert {:ok, pdu, <<>>} = path |> Fixture.read!() |> PDU.decode()
    pdu
  end

  defp encode(pdu), do: pdu |> PDU.encode() |> IO.iodata_to_binary()
end
