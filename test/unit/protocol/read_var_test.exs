defmodule S7.Protocol.ReadVarTest do
  use ExUnit.Case, async: true

  alias S7.{Address, Error}
  alias S7.Protocol.{PDU, ReadVar}
  alias S7.Test.Fixture

  test "encodes a one-item DB word request" do
    address = %Address{area: :db, db_number: 1, byte_offset: 20, data_type: :word}
    assert {:ok, request} = ReadVar.request(address, 42)

    assert IO.iodata_to_binary(PDU.encode(request)) ==
             <<0x32, 1, 0, 0, 0, 42, 0, 14, 0, 0, 0x04, 1, 0x12, 0x0A, 0x10, 0x04, 0, 1, 0, 1,
               0x84, 0, 0, 160>>
  end

  test "maps the capture-derived PLC item error" do
    address = %Address{area: :db, db_number: 1, byte_offset: 0, data_type: :byte}
    assert {:ok, response, <<>>} = PDU.decode(Fixture.read!("read/object_not_found_response.bin"))

    assert {:error, %Error{reason: :object_not_found, code: 0x0A}} =
             ReadVar.decode_response(response, address, 0)
  end

  test "decodes typed successful responses and raw bytes" do
    cases = [
      {:bit, :bit, 1, <<1>>, true},
      {:byte, :byte, 8, <<0xA5>>, 0xA5},
      {:word, :byte, 16, <<0x04, 0xD2>>, 1234},
      {:dword, :byte, 32, <<0x12, 0x34, 0x56, 0x78>>, 0x12345678},
      {:int, :integer, 16, <<0xFF, 0xFE>>, -2},
      {:dint, :integer, 32, <<0xFF, 0xFF, 0xFF, 0xFE>>, -2},
      {:real, :real, 4, <<0x41, 0x48, 0, 0>>, 12.5}
    ]

    for {data_type, transport, length, payload, expected} <- cases do
      address = %Address{area: :markers, byte_offset: 0, data_type: data_type}
      response = response(7, transport, length, payload)

      assert ReadVar.decode_raw_response(response, address, 7) == {:ok, payload}
      assert ReadVar.decode_response(response, address, 7) == {:ok, expected}
    end
  end

  test "encodes and decodes one fixed-count item" do
    address = %Address{area: :db, db_number: 1, byte_offset: 20, data_type: :word, count: 3}
    assert {:ok, request} = ReadVar.request(address, 9)

    assert <<0x04, 1, _prefix::binary-size(4), 0, 3, _rest::binary>> = request.parameters

    response = response(9, :byte, 48, <<1::16, 2::16, 3::16>>)
    assert ReadVar.decode_response(response, address, 9) == {:ok, [1, 2, 3]}
    assert ReadVar.decode_raw_response(response, address, 9) == {:ok, <<1::16, 2::16, 3::16>>}
    assert ReadVar.response_size(address) == {:ok, 24}

    wrong_length = response(9, :byte, 40, <<1::16, 2::16, 3::16>>)

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(wrong_length, address, 9)
  end

  test "decodes semantic and alternate classic transports" do
    date = %Address{area: :db, db_number: 1, byte_offset: 0, data_type: :date}
    character = %{date | data_type: :char, byte_offset: 2}
    dint = %{date | data_type: :dint, byte_offset: 4}
    counter = %Address{area: :counters, element_offset: 3, data_type: :counter}

    assert ReadVar.decode_response(response(4, :byte, 16, <<0, 1>>), date, 4) ==
             {:ok, ~D[1990-01-02]}

    assert ReadVar.decode_response(response(4, :octet, 1, "A"), character, 4) == {:ok, "A"}

    assert ReadVar.decode_response(response(4, :dinteger, 4, <<0, 0, 0, 42>>), dint, 4) ==
             {:ok, 42}

    assert ReadVar.decode_response(response(4, :octet, 2, <<1, 0x23>>), counter, 4) ==
             {:ok, 123}
  end

  test "encodes and decodes multiple aligned items in request order" do
    byte = %Address{area: :markers, byte_offset: 0, data_type: :byte}
    word = %Address{area: :db, db_number: 1, byte_offset: 2, data_type: :word}

    assert {:ok, request} = ReadVar.request_many([byte, word], 12)
    assert <<0x04, 2, first::binary-size(12), second::binary-size(12)>> = request.parameters
    assert {:ok, %{count: 1, area: :markers}, <<>>} = S7.Protocol.Item.decode(first)
    assert {:ok, %{count: 1, area: :db}, <<>>} = S7.Protocol.Item.decode(second)

    data = <<0xFF, 0x04, 0, 8, 0xAA, 0, 0xFF, 0x04, 0, 16, 0x12, 0x34>>
    response = PDU.new(:ack_data, 12, <<0x04, 2>>, data)

    assert ReadVar.decode_responses(response, [byte, word], 12) ==
             {:ok, [{:ok, 0xAA}, {:ok, 0x1234}]}

    assert ReadVar.decode_raw_responses(response, [byte, word], 12) ==
             {:ok, [{:ok, <<0xAA>>}, {:ok, <<0x12, 0x34>>}]}
  end

  test "preserves PLC errors per item and consumes alignment padding" do
    byte = %Address{area: :markers, byte_offset: 0, data_type: :byte}
    missing = %Address{area: :db, db_number: 99, byte_offset: 0, data_type: :word}
    word = %Address{area: :markers, byte_offset: 2, data_type: :word}

    data =
      <<0xFF, 0x04, 0, 8, 1, 0, 0x0A, 0, 0, 0, 0xFF, 0x04, 0, 16, 0x12, 0x34>>

    response = PDU.new(:ack_data, 3, <<0x04, 3>>, data)

    assert {:ok,
            [
              {:ok, 1},
              {:error, %Error{reason: :object_not_found, code: 0x0A}},
              {:ok, 0x1234}
            ]} = ReadVar.decode_responses(response, [byte, missing, word], 3)

    nonzero_padding =
      put_in(response.data, :binary.part(data, 0, 5) <> <<1>> <> :binary.part(data, 6, 10))

    assert {:ok, [{:ok, 1}, {:error, %Error{reason: :object_not_found}}, {:ok, 0x1234}]} =
             ReadVar.decode_responses(nonzero_padding, [byte, missing, word], 3)

    missing_padding = put_in(response.data, :binary.part(data, 0, 5) <> :binary.part(data, 6, 10))

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_responses(missing_padding, [byte, missing, word], 3)
  end

  test "rejects invalid multi-item counts and response counts" do
    address = %Address{area: :markers, byte_offset: 0, data_type: :byte}
    assert {:error, %Error{reason: :invalid_item_count}} = ReadVar.request_many([], 1)

    assert {:error, %Error{reason: :invalid_item_count}} =
             ReadVar.request_many(List.duplicate(address, 256), 1)

    response = PDU.new(:ack_data, 1, <<0x04, 2>>, <<0xFF, 0x04, 0, 8, 1>>)

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_responses(response, [address], 1)
  end

  test "rejects wrong references, truncated payloads, and transport mismatches" do
    address = %Address{area: :markers, byte_offset: 0, data_type: :word}
    response = response(7, :byte, 16, <<0, 1>>)

    assert {:error, %Error{reason: :unexpected_pdu_reference}} =
             ReadVar.decode_response(response, address, 8)

    truncated = PDU.new(:ack_data, 7, <<4, 1>>, <<0xFF, 0x04, 0, 16, 1>>)

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(truncated, address, 7)

    mismatch = response(7, :integer, 16, <<0, 1>>)

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(mismatch, address, 7)

    invalid_parameters = %{response | parameters: <<0x04, 2>>}

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(invalid_parameters, address, 7)

    trailing_data = %{response | data: response.data <> <<0>>}

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(trailing_data, address, 7)

    invalid_item = %{response | data: <<0xFF, 0xFF, 0, 0>>}

    assert {:error, %Error{reason: :malformed_response}} =
             ReadVar.decode_response(invalid_item, address, 7)
  end

  defp response(reference, transport, encoded_length, payload) do
    transport_code =
      %{
        bit: 0x03,
        byte: 0x04,
        integer: 0x05,
        dinteger: 0x06,
        real: 0x07,
        octet: 0x09
      }[transport]

    data = <<0xFF, transport_code, encoded_length::unsigned-big-16, payload::binary>>
    PDU.new(:ack_data, reference, <<0x04, 1>>, data)
  end
end
