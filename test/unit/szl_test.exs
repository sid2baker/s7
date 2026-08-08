defmodule S7.SZLTest do
  use ExUnit.Case, async: true

  alias S7.{CPInfo, CPUInfo, Error, OrderCode, PLCStatus, SZL}
  alias S7.SZL.Metadata

  test "decodes exact record geometry and rejects malformed declarations" do
    raw = <<2::16, 2::16, 0x0011::16, 0x001C::16>>

    assert {:ok,
            %SZL{
              record_length: 2,
              record_count: 2,
              records: [<<0x0011::16>>, <<0x001C::16>>],
              raw: ^raw
            } = szl} = SZL.decode(0, 0, raw)

    assert Metadata.available_ids(szl) == {:ok, [0x0011, 0x001C]}

    assert {:error, %Error{reason: :malformed_response}} = SZL.decode(0, 0, <<0, 2, 0>>)

    assert {:error, %Error{reason: :malformed_response}} =
             SZL.decode(0, 0, <<2::16, 2::16, 0x0011::16>>)

    assert {:error, %Error{reason: :malformed_response}} =
             SZL.decode(0, 0, <<0::16, 1::16>>)
  end

  test "validates request limits without touching the connection" do
    assert {:ok, %{max_bytes: 1024, max_fragments: 3}} =
             SZL.validate_request(0x11, 0, [max_bytes: 1024, max_fragments: 3], :read_szl)

    assert {:error, %Error{reason: :invalid_szl_request}} =
             SZL.validate_request(-1, 0, [], :read_szl)

    assert {:error, %Error{reason: :invalid_option}} =
             SZL.validate_request(1, 0, [max_fragments: 0], :read_szl)

    assert {:error, %Error{reason: :invalid_option}} =
             SZL.validate_request(1, 0, [unknown: 1], :read_szl)
  end

  test "decodes documented module, component, communication, and status records" do
    order_record =
      <<1::16, fixed_text("6ES7 315-2EH14-0AB0", 20)::binary, 0::16, 3::16, 2::8, 1::8>>

    assert {:ok, order_szl} = encoded_szl(0x0011, 28, [order_record])

    assert {:ok,
            %OrderCode{code: "6ES7 315-2EH14-0AB0", version: {3, 2, 1}, record: ^order_record}} =
             Metadata.order_code(order_szl)

    components = [
      component(1, "Plant A"),
      component(2, "CPU module"),
      component(4, "Original Siemens Equipment"),
      component(5, "SERIAL-123"),
      component(7, "CPU 315-2 PN/DP")
    ]

    assert {:ok, cpu_szl} = encoded_szl(0x001C, 34, components)

    assert {:ok,
            %CPUInfo{
              automation_system_name: "Plant A",
              module_name: "CPU module",
              copyright: "Original Siemens Equipment",
              serial_number: "SERIAL-123",
              module_type_name: "CPU 315-2 PN/DP"
            }} = Metadata.cpu_info(cpu_szl)

    cp_record = <<1::16, 480::16, 8::16, 187_500::32, 12_000_000::32>>
    assert {:ok, cp_szl} = encoded_szl(0x0131, 14, [cp_record], 1)

    assert {:ok,
            %CPInfo{
              max_pdu_length: 480,
              max_connections: 8,
              max_mpi_rate: 187_500,
              max_bus_rate: 12_000_000
            }} = Metadata.cp_info(cp_szl)

    status_record = <<0::16, 0, 8>>
    assert {:ok, status_szl} = encoded_szl(0x0424, 4, [status_record])

    assert {:ok, %PLCStatus{state: :run, code: 8, record: ^status_record}} =
             Metadata.plc_status(status_szl)
  end

  defp encoded_szl(id, length, records, index \\ 0) do
    raw = IO.iodata_to_binary([<<length::16, length(records)::16>>, records])
    SZL.decode(id, index, raw)
  end

  defp component(index, text), do: <<index::16, fixed_text(text, 32)::binary>>

  defp fixed_text(text, size) do
    binary_part(text <> :binary.copy(<<0>>, size), 0, size)
  end
end
