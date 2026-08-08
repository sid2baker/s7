fixtures = %{
  "test/fixtures/cotp/connection_request.bin" => "11E00000000100C1020100C2020102C0010A",
  "test/fixtures/cotp/connection_confirm.bin" => "11D00001000100C1020102C2020100C0010A",
  "test/fixtures/cotp/data.bin" => "02F08032010000FFFF00080000F000000100010780",
  "test/fixtures/cotp/disconnect_request.bin" => "0B800001000280E003AABBCC",
  "test/fixtures/cotp/disconnect_confirm.bin" => "08C000010002C3017A",
  "test/fixtures/cotp/error.bin" => "0970000102C10302F081",
  "test/fixtures/setup/request.bin" => "32010000FFFF00080000F000000100010780",
  "test/fixtures/setup/response.bin" => "32030000FFFF000800000000F0000001000100F0",
  "test/fixtures/read/db1_64_bytes_request.bin" =>
    "320100000000000E00000401120A10020040000184000000",
  "test/fixtures/read/object_not_found_response.bin" => "32030000000000020004000004010A000000",
  "test/fixtures/read/multi_8_request.bin" =>
    "320100000002006200000408120A10010001000184000010120A10080001000184000040120A10060001000184000020120A10040001000184000000120A10010001000083000008120A10010001000083000009120A101D000100001D000000120A101C000100001C000000",
  "test/fixtures/read/multi_8_response.bin" =>
    "3203000000020002003400000408FF0300010100FF070004AABBCCDDFF040020FEADBEEFFF040010BABEFF0300010100FF0300010100FF0900022504FF0900020011",
  "test/fixtures/write/m1_0_request.bin" =>
    "320100000001000E00050501120A100100010000830000080003000100",
  "test/fixtures/write/success_response.bin" => "3203000000010002000100000501FF",
  "test/fixtures/userdata/read_szl_request.bin" =>
    "32070000002A000800080001120411440100FF09000400110000",
  "test/fixtures/userdata/read_szl_response.bin" =>
    "32070000002A000C000E000112081284010003000000FF09000A00110000000200010001",
  "test/fixtures/userdata/read_szl_continuation.bin" =>
    "32070000002B000C00040001120812440107000000000A000000"
}

Enum.each(fixtures, fn {path, hex} ->
  File.mkdir_p!(Path.dirname(path))
  File.write!(path, Base.decode16!(hex))
end)
