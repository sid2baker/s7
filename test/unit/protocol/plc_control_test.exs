defmodule S7.Protocol.PLCControlTest do
  use ExUnit.Case, async: true

  alias S7.Error
  alias S7.Protocol.{PDU, PLCControl}
  alias S7.Test.Fixture

  @exchanges [
    {:stop_cpu, 0x3500, "stop"},
    {:warm_start_cpu, 0x2000, "warm_start"},
    {:cold_start_cpu, 0x1F00, "cold_start"},
    {:copy_ram_to_rom, 0x0A00, "copy_ram_to_rom"},
    {:compress_memory, 0x1E00, "compress_memory"}
  ]

  test "encodes and decodes every bounded CPU control exchange" do
    for {action, reference, fixture} <- @exchanges do
      assert {:ok, request} = PLCControl.request(action, action)
      request = put_in(request.header.pdu_reference, reference)

      assert encode(request) == Fixture.read!("control/#{fixture}_request.bin")
      assert PLCControl.decode_request(request, action) == {:ok, action}

      response = fixture_pdu("control/#{fixture}_response.bin")
      assert PLCControl.decode_response(response, action, action) == :ok
    end
  end

  test "rejects unsupported actions and malformed request envelopes" do
    assert {:error, %Error{reason: :invalid_control_action}} =
             PLCControl.request(:memory_reset, :control)

    valid = fixture_pdu("control/stop_request.bin")

    for malformed <- [
          %{valid | data: <<0>>},
          put_in(valid.header.rosctr, :ack_data),
          %{valid | parameters: <<0x29, 0>>}
        ] do
      assert {:error, %Error{reason: :malformed_response}} =
               PLCControl.decode_request(malformed, :control)
    end
  end

  test "maps PLC rejections and rejects mismatched response envelopes" do
    rejected = PDU.new(:ack, 1, <<>>, <<>>, error_class: 0xD2, error_code: 0x41)

    assert {:error, %Error{reason: :access_denied, code: 0xD241}} =
             PLCControl.decode_response(rejected, :stop_cpu, :stop_cpu)

    for malformed <- [
          PDU.new(:ack_data, 1, <<0x28>>),
          PDU.new(:ack_data, 1, <<0x29>>, <<0>>),
          PDU.new(:job, 1, <<0x29>>)
        ] do
      assert {:error, %Error{reason: :malformed_response}} =
               PLCControl.decode_response(malformed, :stop_cpu, :stop_cpu)
    end

    assert {:error, %Error{reason: :invalid_control_action}} =
             PLCControl.decode_response(
               PDU.new(:ack_data, 1, <<0x28>>),
               :memory_reset,
               :control
             )
  end

  defp fixture_pdu(path) do
    assert {:ok, pdu, <<>>} = path |> Fixture.read!() |> PDU.decode()
    pdu
  end

  defp encode(pdu), do: pdu |> PDU.encode() |> IO.iodata_to_binary()
end
