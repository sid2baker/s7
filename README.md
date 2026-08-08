# S7

An Elixir client for classic S7comm over RFC 1006. The protocol surface is deliberately focused:
COTP connection setup, S7 Setup Communication, and single- or multi-item Read Var and Write Var
jobs. One S7ANY item may represent either a scalar or a fixed-count range.

The implementation keeps protocol codecs pure and gives the TCP socket to one `:gen_statem`
process. Its `active: :once` request engine correlates responses by PDU reference, bounds queued
and in-flight work, and keeps negotiated limits in connection state.

## Status

The classic core and loopback interoperability suite support scalar, counted, and multi-item
reads and writes. CI also builds a server from a pinned Snap7 revision and verifies automatic PDU
splitting and read-after-write for every supported area and value type. PLCSIM Advanced and
physical Siemens hardware remain external release gates.

S7comm-plus, symbolic addressing, optimized/protected DB access, block transfer, PLC control,
userdata, alarms, and diagnostics are not supported.

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

Counted addresses return lists from typed reads and accept lists for typed writes:

```elixir
words = %S7.Address{
  area: :db,
  db_number: 1,
  byte_offset: 20,
  data_type: :word,
  count: 4
}

:ok = S7.Client.write(client, words, [1, 2, 3, 4])
{:ok, [1, 2, 3, 4]} = S7.Client.read(client, words)
{:ok, <<0, 1, 0, 2, 0, 3, 0, 4>>} = S7.Client.read_raw(client, words)
```

The client returned by `connect/2` is the PID that owns the socket. All public failures use
`%S7.Error{}`. A multi-item operation that stops after execution begins returns
`{:error, error, results}` so partial and indeterminate outcomes are not discarded.

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
| `:max_jobs` | `1` | Requested and local maximum number of concurrent S7 jobs |
| `:queue_limit` | `64` | Maximum callers waiting behind in-flight jobs; `0` disables waiting |
| `:reconnect` | `false` | Establish fresh sessions after loss; `start_link/1` also survives unavailable startup |
| `:reconnect_min_delay` | `250` | Initial reconnect backoff in milliseconds |
| `:reconnect_max_delay` | `30000` | Upper bound for reconnect delay, including jitter |
| `:reconnect_max_attempts` | `:infinity` | Attempt cap before the process remains `:disconnected` |
| `:reconnect_jitter` | `0.2` | Random proportional backoff jitter from `0.0` to `1.0` |
| `:max_tpkt_size` | `65535` | Maximum accepted TPKT frame size |
| `:receive_buffer_limit` | derived | Maximum buffered TCP bytes; at least `:max_tpkt_size` |
| `:max_items_per_pdu` | `20` | Conservative peer-compatible Read/Write Var item limit |

The PLC may negotiate smaller PDU or job limits. `S7.Client.info/1` reports negotiated limits,
the next reference, and current queue/in-flight counts. The default remains one job for broad PLC
compatibility; opt into concurrency with `max_jobs: n` only when the peer supports it.

### Supervision And Recovery

Use `start_link/1` under a supervisor when the client must retain a stable PID or registered name:

```elixir
children = [
  {S7.Client,
   host: "192.168.1.10",
   name: MyApp.PLC,
   rack: 0,
   slot: 2,
   reconnect: true}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

An unavailable supervised client with reconnect enabled starts in `:reconnecting`. Backoff is
bounded and reset after a successful Setup Communication exchange. Session loss fails all accepted
calls before reconnecting; requests and writes are never replayed. `S7.Client.reconnect/1` starts a
fresh explicit attempt after a configured attempt cap is reached.

Immediate close remains the default. To finish accepted work while rejecting new calls:

```elixir
:ok = S7.Client.close(client, mode: :drain, timeout: 5_000)
```

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

Supported types are `:bit`, `:byte`, `:word`, `:dword`, `:int`, `:dint`, and `:real`. All except
`:bit` support a `count` greater than one. Wire conversion is independently available through
`S7.Data.encode/2`, `S7.Data.encode/3`, `S7.Data.decode/2`, and `S7.Data.decode/3`.

`S7.Client.write_raw/3` accepts an already encoded binary whose size exactly matches the address
type and count. Raw access does not bypass address validation or negotiated PDU limits.

Multi-item operations preserve input order and split automatically:

```elixir
{:ok, results} = S7.Client.read_multi(client, ["DB1.DBW0", "MW10", "IW0"])
values = Enum.map(results, &{&1.status, &1.value})

{:ok, results} =
  S7.Client.write_multi(client, [
    {"DB1.DBW0", 123},
    {"MW10", 456}
  ])
```

Each entry is an `%S7.Result{}` with status `:ok`, `:error`, `:indeterminate`, or
`:not_attempted`. The last two statuses matter when a multi-PDU write loses its connection.

## Architecture

```text
S7.Client
  -> S7.Connection (:gen_statem, active-once :gen_tcp owner)
    -> bounded queue / PDU-reference correlation / request timers / reconnect backoff
    -> S7.Protocol.{SetupCommunication, ReadVar, WriteVar}
      -> S7.Protocol.PDU / Header / Item / DataItem
        -> S7.Transport.COTP
          -> S7.Transport.TPKT
```

TPKT decoding supports incomplete and concatenated frames. The connection also reassembles bounded
COTP Data fragments. PDU references are not reused while in flight, responses may arrive out of
order, and a request timeout invalidates the session so late bytes cannot affect later work.

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
