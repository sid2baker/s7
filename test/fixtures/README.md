# Golden fixtures

These binary fixtures cover the v0.1 COTP and S7comm wire surface.

The Setup and Read Var S7 payloads were extracted from the captures documented in
`resources/gmiru-s7comm/capture-catalog.md`, pinned there to commit
`88f35a601de45fa29b0b36048a30ae4a1e925320` of `gymgit/s7-pcaps`.

The COTP control/data frames and the single-bit Write Var pair are normalized from the same
capture set and the corresponding decoded observations. DR, DC, and ER use the normative X.224
field layouts with explicit diagnostic parameters.

The userdata Read SZL fixtures are normalized from the Snap7 request/continuation structures and
cross-checked by the pinned Snap7 interoperability suite. The response contains a small synthetic
but internally consistent SZL record so geometry checks remain deterministic. Fixture assertions
always check both directions:

The block directory fixtures are S7 PDU bytes from frames 87-100 and 135-136 of the pinned
`tia_s300_goOnline.pcapng` capture. They include count-by-type, DB listing, a real two-fragment SFC
listing, and a successful DB1 metadata response.

Clock fixtures are S7 PDU bytes from frames 45-48 of the pinned
`snap7_s300_everything.pcapng` capture. The credential-free security response is frame 4 of
`step7_s300_AuthPassword.pcapng`. Password-bearing request bytes are intentionally not committed;
the transform is tested with a non-secret test value instead.

Block-upload fixtures are S7 PDU bytes from frames 17-22 and 44 of the pinned
`snap7_s300_everything.pcapng` capture. They contain a successful full SDB0
upload and a PLC-reported OB0 rejection. The complete uploaded load-memory
image remains embedded in the captured segment response.

Block-download fixtures are S7 PDU bytes from frames 87-94 of the pinned
`step7_s300_download.pcapng` capture. They contain Request Download, the
PLC-driven Download Block and Download Ended jobs and replies, and `_INSE`
activation for a complete 216-byte DB1 image. The `_DELE` DB1 fixture uses the
same independently documented PI-Service layout with the delete command.

```text
fixture -> decode -> expected struct
expected struct -> encode -> fixture
```

`read/multi_8_request.bin` and `read/multi_8_response.bin` are S7 payloads from frames 6 and 9 of
the pinned WinCC S7-300 capture. They retain its eight-item parameter block, mixed response
transports, and alignment bytes.

Regenerate the `.bin` files from their reviewed hexadecimal source with:

```bash
elixir scripts/build_test_fixtures.exs
```
