# S7

An Elixir client for classic S7comm over RFC 1006. The v0.1 protocol surface is deliberately
small: COTP connection setup, S7 Setup Communication, and one-item Read Var and Write Var jobs.

The implementation keeps protocol codecs pure and gives the TCP socket to one `:gen_statem`
process. Calls are serialized, PDU references are correlated, and negotiated PDU limits are kept
in connection state.

## Status

The v0.1 implementation and loopback interoperability suite are complete. CI also builds a server
from a pinned Snap7 revision and verifies negotiation plus read-after-write for every supported
area and scalar type. PLCSIM Advanced and physical Siemens hardware remain external release gates.

S7comm-plus, symbolic addressing, optimized/protected DB access, multi-item operations, block
transfer, PLC control, userdata, alarms, and diagnostics are not supported.

## Usage

```elixir
{:ok, client} =
  S7.Client.connect("192.168.1.10",
    rack: 0,
    slot: 2
  )

{:ok, current} = S7.Client.read(client, "DB1.DBW0")
:ok = S7.Client.write(client, "DB1.DBW0", current + 1)
{:ok, raw} = S7.Client.read_raw(client, "DB1.DBW0")
:ok = S7.Client.close(client)
```

The client returned by `connect/2` is the PID that owns the socket. All public failures use
`{:error, %S7.Error{}}`.

### Connection Options

| Option | Default | Meaning |
| --- | --- | --- |
| `:rack` | `0` | PLC rack used to construct the destination TSAP |
| `:slot` | `2` | PLC slot used to construct the destination TSAP |
| `:connection_type` | `:programming_device` | TSAP role; also accepts `:operator_panel` and `:basic` |
| `:src_tsap` | `<<0x01, 0x00>>` | Explicit calling TSAP |
| `:dst_tsap` | derived | Explicit called TSAP; bypasses rack/slot construction |
| `:port` | `102` | RFC 1006 TCP port |
| `:timeout` | `5000` | Connect and request timeout in milliseconds |
| `:tpdu_size` | `1024` | Requested COTP TPDU size |
| `:pdu_size` | `480` | Requested S7 PDU size |
| `:max_tpkt_size` | `65535` | Maximum accepted TPKT frame size |
| `:receive_buffer_limit` | derived | Maximum buffered TCP bytes; at least `:max_tpkt_size` |

The PLC may negotiate a smaller S7 PDU. Inspect the active values with `S7.Client.info/1`.

## Addresses And Values

String parsing supports:

```text
DB1.DBX20.3  DB1.DBB20  DB1.DBW20  DB1.DBD20
M10.0        MB10       MW10       MD10
I0.0         IB0        IW0        ID0
Q0.0         QB0        QW0        QD0
```

String `B`, `W`, and `D` forms are unsigned `:byte`, `:word`, and `:dword` values. Use an explicit
address when the same bytes represent a signed integer or REAL:

```elixir
temperature = %S7.Address{
  area: :db,
  db_number: 1,
  byte_offset: 20,
  data_type: :real
}

{:ok, 12.5} = S7.Client.read(client, temperature)
```

Supported scalar types are `:bit`, `:byte`, `:word`, `:dword`, `:int`, `:dint`, and `:real`.
Wire conversion is independently available through `S7.Data.encode/2` and `S7.Data.decode/2`.

## Architecture

```text
S7.Client
  -> S7.Connection (:gen_statem, passive :gen_tcp owner)
    -> S7.Protocol.{SetupCommunication, ReadVar, WriteVar}
      -> S7.Protocol.PDU / Header / Item / DataItem
        -> S7.Transport.COTP
          -> S7.Transport.TPKT
```

TPKT decoding supports incomplete and concatenated frames. The connection also reassembles bounded
COTP Data fragments. v0.1 permits one outstanding request, even if the peer negotiates a larger
job queue.

The tracked design contract is documented in:

- [Architecture](docs/architecture.md)
- [Protocol support](docs/protocol-support.md)
- [Errors and retries](docs/error-and-retry-semantics.md)
- [Roadmap to 1.0](docs/roadmap.md)

## Development

```bash
mix deps.get
mix ci
```

The CI alias runs compilation with warnings as errors, formatting, unit/property/integration
tests with a 90% coverage gate, strict Credo, Dialyzer, clone detection, and architecture checks.
The loopback PLC test uses real TCP and intentionally fragments responses at both TCP and COTP
boundaries.

Run the pinned Snap7 interoperability suite locally with:

```bash
bash scripts/run_snap7_integration.sh
```

The script uses the ignored local Snap7 reference when present and otherwise checks out the pinned
revision into a temporary directory.

With Docker available, capture the same exchange and require tshark to identify Setup, Read Var,
and Write Var without malformed packets:

```bash
bash scripts/run_snap7_packet_check.sh
```

CI runs the packet check and retains its PCAP artifact for seven days.

Golden fixtures live in [`test/fixtures`](test/fixtures/README.md). Rebuild their binary files with
`elixir scripts/build_test_fixtures.exs`.

### Local Protocol References

Source manuals, reference implementations, captures, and generated Markdown extracts under
`resources/` are local development references and are intentionally excluded from version control.
The local index files are `resources/s7-1500-communication-manual.md` and
`resources/gmiru-s7comm/README.md`. Rebuild the S7-1500 manual extract with
`elixir scripts/extract_s7_manual.exs`.

## Installation

The package is not published to Hex yet. Until it is, use a Git dependency or a local path.
