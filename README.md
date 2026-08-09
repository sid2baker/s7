# S7

An Elixir client for classic S7comm over RFC 1006. The protocol surface includes COTP connection
setup, S7 Setup Communication, single- or multi-item Read Var and Write Var jobs, bounded
userdata-backed System Status List (SZL/SSL) reads, and classic block directory and metadata
queries. Bounded classic block upload, PLC clock access, and classic session-password
authorization are also supported. Destructive block download, replacement, and deletion are
available only through an explicit two-level opt-in, as are CPU stop/start, RAM-to-ROM copy, and
memory compression. Capture-backed read-only programmer diagnostics and one-shot variable-status
sampling are raw-first and bounded. Typed fixed-cycle subscriptions and raw change-driven cyclic
jobs use owner-bound, session-local handles with bounded pull queues. Classic `ALARM_S` and
`ALARM_8` subscriptions, queries, indications, and explicit acknowledgments use the same bounded
ownership model. One S7ANY item may represent either a scalar or a fixed-count range.

The implementation keeps protocol codecs pure and gives the TCP socket to one `:gen_statem`
process. Its `active: :once` request engine correlates responses by PDU reference, bounds queued
and in-flight work, and keeps negotiated limits in connection state.

## Status

The classic core and loopback interoperability suite support scalar, counted, and multi-item
reads and writes. CI also builds a server from a pinned Snap7 revision and verifies automatic PDU
splitting and read-after-write for every supported area and value type. PLCSIM Advanced and
physical Siemens hardware remain external release gates, so `0.1.0` remains a release candidate.

S7comm-plus, symbolic addressing, optimized DB access, and destructive programmer commands are
not supported. The common classic userdata envelope is implemented for SZL, block-directory,
clock, protected-session, evidence-backed read-only programmer jobs, cyclic subscriptions, and
classic alarms. Alarm success paths remain subject to named physical-device qualification.

## Usage

```elixir
{:ok, client} =
  S7.connect("192.168.1.10",
    rack: 0,
    slot: 2
  )

{:ok, current} = S7.read(client, "DB1.DBW0")
:ok = S7.write(client, "DB1.DBW0", current + 1)
{:ok, raw} = S7.read_raw(client, "DB1.DBW0")
{:ok, %S7.PLC.OrderCode{code: order_code}} = S7.order_code(client)
{:ok, dbs} = S7.list_blocks(client, :db)
{:ok, %S7.PLC.Clock{datetime: plc_time}} = S7.read_clock(client)
{:ok, %S7.Programmer.VariableStatus{items: status_items}} =
  S7.variable_status(client, ["MB0", "DB1.DBW0"])
{:ok, cyclic} = S7.subscribe_cyclic(client, ["DB1.DBW0"], interval: 1_000)
{:ok, %S7.Cyclic.Event{items: [%S7.Cyclic.Event.Item{value: next_value}]}} =
  S7.next_cyclic(client, cyclic)
:ok = S7.unsubscribe_cyclic(client, cyclic)
:ok = S7.close(client)
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

:ok = S7.write(client, words, [1, 2, 3, 4])
{:ok, [1, 2, 3, 4]} = S7.read(client, words)
{:ok, <<0, 1, 0, 2, 0, 3, 0, 4>>} = S7.read_raw(client, words)
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
| `:subscription_limit` | `16` | Maximum session-local userdata indication subscriptions |
| `:allow_destructive` | `false` | Enables destructive APIs; every call still requires its exact confirmation atom |

The PLC may negotiate smaller PDU or job limits. `S7.info/1` reports negotiated limits,
the next reference, and current queue/in-flight counts. The default remains one job for broad PLC
compatibility; opt into concurrency with `max_jobs: n` only when the peer supports it.

### Supervision And Recovery

Use `start_link/1` under a supervisor when the client must retain a stable PID or registered name:

```elixir
children = [
  {S7,
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
calls before reconnecting; requests and writes are never replayed. `S7.reconnect/1` starts a
fresh explicit attempt after a configured attempt cap is reached.

Immediate close remains the default. It fails accepted work, sends a COTP
Disconnect Request when a COTP session exists, and waits boundedly for a
Disconnect Confirm or TCP close before forcing socket closure. To finish
accepted work before that exchange while rejecting new calls:

```elixir
:ok = S7.close(client, mode: :drain, timeout: 5_000)
```

## Addresses And Values

String parsing supports:

```text
DB1.DBX20.3  DB1.DBB20  DB1.DBW20  DB1.DBD20
DBI1.DBIX0.0 DBI1.DBIB0 DBI1.DBIW0 DBI1.DBID0
M10.0        MB10       MW10       MD10
I0.0         IB0        IW0        ID0
Q0.0         QB0        QW0        QD0
P0.0         PB0        PW0        PD0
L0.0         LB0        LW0        LD0
V0.0         VB0        VW0        VD0
C10          T5
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

{:ok, 12.5} = S7.read(client, temperature)
```

The address model also supports peripheral, instance DB, local, previous-local,
counter, and timer areas. Counters and timers use `element_offset`; byte areas
use `byte_offset`. All types except `:bit` support a `count` greater than one.

`S7.Data` provides signed and unsigned 8/16/32/64-bit integers, REAL/LREAL,
byte and wide characters, fixed `{:string, maximum}` and
`{:wstring, maximum}` storage, `DATE`, `TIME`, `TIME_OF_DAY`,
`DATE_AND_TIME`, `S5TIME`, counter, and timer codecs. Address semantics are
separate from S7ANY transport selection. The default uses broadly compatible
byte access where a native transport is not portable; set `transport_size` on
an explicit address to opt into a native S7ANY date/time code.

Wire conversion is independently available through `S7.Data.encode/2`,
`S7.Data.encode/3`, `S7.Data.decode/2`, and `S7.Data.decode/3`.

`S7.write_raw/3` accepts an already encoded binary whose size exactly matches the address
type and count. Raw access does not bypass address validation or negotiated PDU limits.

Multi-item operations preserve input order and split automatically:

```elixir
{:ok, results} = S7.read_multi(client, ["DB1.DBW0", "MW10", "IW0"])
values = Enum.map(results, &{&1.status, &1.value})

{:ok, results} =
  S7.write_multi(client, [
    {"DB1.DBW0", 123},
    {"MW10", 456}
  ])
```

Each entry is an `%S7.Result{}` with status `:ok`, `:error`, `:indeterminate`, or
`:not_attempted`. The last two statuses matter when a multi-PDU write loses its connection.

## System Status Lists

Raw SZL reads preserve record boundaries and bytes while validating the PLC's declared geometry:

```elixir
{:ok, %S7.SZL{record_length: length, records: records}} =
  S7.read_szl(client, 0x0011, 0,
    max_bytes: 1_048_576,
    max_fragments: 64
  )

{:ok, ids} = S7.list_szl(client)
{:ok, %S7.PLC.CPUInfo{} = cpu} = S7.cpu_info(client)
{:ok, %S7.PLC.CPInfo{} = communication} = S7.cp_info(client)
{:ok, %S7.PLC.Status{state: :run}} = S7.plc_status(client)
```

The order-code, component-identification, communication-limit, and status helpers decode known
Siemens layouts. Every typed result retains either its source record or the complete component
map; use `read_szl/4` for CPU-specific and firmware-specific records.

## Block Directory

Classic userdata block services expose inventory and metadata without transferring executable
block images:

```elixir
{:ok, %S7.Block.Inventory{counts: %{db: db_count}}} =
  S7.block_counts(client)

{:ok, [%S7.Block.Entry{} | _] = dbs} =
  S7.list_blocks(client, :db,
    max_bytes: 1_048_576,
    max_fragments: 64
  )

{:ok, %S7.Block.Info{name: name, mc7_size: size}} =
  S7.block_info(client, :db, 1)
```

`list_blocks/3` assembles the PLC's continuation sequence under aggregate byte and fragment
limits. Directory entries and detailed metadata retain raw bytes and preserve unknown language,
type, and security codes. Block upload and download use different stateful Job services and are
not aliases for Read Var, Write Var, or these directory calls.

## Block Upload

Classic block upload retrieves one complete load-memory image through an exclusive, bounded
`Start Upload` / `Upload` / `End Upload` transaction:

```elixir
{:ok, %S7.Block.Image{} = image} =
  S7.upload_block(client, :db, 1,
    max_bytes: 1_048_576,
    max_fragments: 64,
    timeout: 30_000
  )

{:ok, raw_image} = S7.upload_block_raw(client, %S7.Block{type: :db, number: 1})
```

The parsed image retains every original byte, validates the requested block identity and declared
sizes, and exposes known header, timestamp, MC7, and footer fields. Classic MC7 and footer ranges
can overlap, so `S7.Block.Image` also exposes non-overlapping `payload`, `raw_header`, and
`raw_footer` fields. The raw API is available for CPU-specific image variants.

An initial PLC rejection leaves the connection usable. Local byte or fragment limits close the
remote upload cleanly; malformed or ambiguous mid-transaction responses invalidate the session.
Successful upload is qualified by an independently captured real-PLC exchange and the fault
server. The pinned Snap7 server rejects upload with `0xD241`, which the interoperability gate
checks explicitly.

## Destructive Block Management

Block download is a PLC-driven, bidirectional transaction and is not Write Var. It is disabled by
default. Both the connection capability and the operation-specific confirmation are required:

```elixir
{:ok, maintenance_client} =
  S7.connect("192.168.1.10",
    rack: 0,
    slot: 2,
    allow_destructive: true
  )

:ok =
  S7.download_block(maintenance_client, image,
    confirm: :download_block
  )

:ok =
  S7.replace_block(maintenance_client, replacement,
    confirm: :replace_block
  )

:ok =
  S7.delete_block(maintenance_client, :db, 1,
    confirm: :delete_block
  )
```

`download_block_raw/4` and `replace_block_raw/4` validate the complete image and requested block
identity before sending. Download reserves the connection for Request Download, every
PLC-initiated Download Block job, Download Ended, and `_INSE` activation. Responses are split
against the negotiated PDU size. A complete PLC rejection leaves the connection usable; timeout,
disconnect, malformed traffic, or an ambiguous activation response invalidates the session and
returns `details.outcome: :indeterminate`. No destructive operation is replayed after reconnect.

The exact successful transfer is capture- and fault-server-qualified. The pinned Snap7 server
deliberately rejects Request Download, so successful PLCSIM and physical-PLC qualification remains
a release gate. Whether `_INSE` creates or replaces an existing block is PLC-dependent;
`replace_block/3` records explicit caller intent but uses the same classic wire service.

## Destructive CPU Control

CPU control uses a short exclusive transaction and the same two-level policy as block download.
Each action has a distinct confirmation atom:

```elixir
:ok = S7.stop_cpu(maintenance_client, confirm: :stop_cpu)
:ok = S7.warm_start_cpu(maintenance_client, confirm: :warm_start_cpu)
:ok = S7.cold_start_cpu(maintenance_client, confirm: :cold_start_cpu)

# These operations commonly require the CPU to be in STOP.
:ok = S7.copy_ram_to_rom(maintenance_client, confirm: :copy_ram_to_rom)
:ok = S7.compress_memory(maintenance_client, confirm: :compress_memory)
```

All calls accept bounded `:timeout` and `:step_timeout` options. A complete PLC rejection returns
`details.outcome: :rejected` and leaves the session usable. Once a request has been transmitted,
a timeout, disconnect, or malformed response is reported as `:indeterminate` and invalidates the
session. The client never replays CPU control after reconnect.

## PLC Clock And Session Authorization

Classic PLC clock values are timezone-free local civil time:

```elixir
{:ok, %S7.PLC.Clock{datetime: current}} = S7.read_clock(client)
:ok = S7.set_clock(client, ~N[2030-02-03 04:05:06.789])
```

`set_clock/2` is state-changing and is never replayed after an ambiguous outcome. The returned
clock struct retains the complete wire timestamp because observed PLCs do not use its century hint
consistently.

Classic protected-session login changes authorization for the current connection only:

```elixir
password = System.fetch_env!("S7_PASSWORD")
:ok = S7.authenticate(client, password)
:ok = S7.logout(client)
```

Passwords are one to eight printable ASCII bytes. Authentication is an ordering barrier: earlier
jobs complete before login/logout and later jobs wait behind it. Authorization is cleared by
logout or session loss and is never restored automatically after reconnect. This legacy exchange
provides no encryption, integrity, or peer authentication; see [Security policy](SECURITY.md).

## Cyclic Subscriptions

Fixed-cycle subscriptions decode standard S7ANY values using the same address and value model as
Read Var:

```elixir
{:ok, subscription} =
  S7.subscribe_cyclic(client, ["MW10", "DB1.DBD20"],
    interval: 1_000,
    queue_limit: 32
  )

initial_snapshot = subscription.initial
{:ok, %S7.Cyclic.Event{items: items}} = S7.next_cyclic(client, subscription)
:ok = S7.unsubscribe_cyclic(client, subscription)
```

Intervals must be represented exactly by the classic 100 ms, 1 s, or 10 s wire bases; the client
never rounds. `subscribe_cyclic_raw/4` additionally supports fixed and change-driven jobs using
complete S7ANY or DBREAD specifications, and `modify_cyclic_raw/4` replaces a change-driven item
set without changing its remote job ID. CPU-specific change records remain raw.

The creating process owns the handle. Pull timeouts leave the remote job active. Queue overflow is
terminal for event delivery but `unsubscribe_cyclic/3` still releases the PLC job. Owner death or
an ambiguous setup, modification, or teardown invalidates the session; reconnect never restores a
subscription, and handles from an earlier session are rejected.

## Classic Alarms

Alarm subscriptions expose validated timestamps and known object headers while retaining every
wire record and CPU-specific associated value:

```elixir
{:ok, alarms} =
  S7.subscribe_alarms(client, :alarm_8,
    queue_limit: 64
  )

{:ok, %S7.Alarm.Event{objects: [object | _]} = event} =
  S7.next_alarm(client, alarms)

{:ok, %S7.Alarm.Query{records: records}} =
  S7.query_alarms(client, :alarm_8)

:ok = S7.acknowledge_alarm(client, object)
{:ok, results} = S7.acknowledge_alarms(client, event)
:ok = S7.unsubscribe_alarms(client, alarms)
```

Use `:alarm_s` for the S7-300-style path and `:alarm_8` for the S7-400-style path. Events are
delivered in receive order without deduplication. Handles belong to their creating process and
current S7 session; reconnect requires explicit resubscription. Alarm acknowledgment is
state-changing and is never replayed. A complete PLC rejection leaves the session usable, while a
missing or malformed response after transmission is indeterminate and invalidates the session.
Query records and associated values preserve raw bytes for CPU-family-specific variants.

## Architecture

```text
S7
  -> S7.Connection (:gen_statem, active-once :gen_tcp owner)
    -> bounded queue / PDU-reference correlation / request timers / reconnect backoff
    -> S7.Protocol.{SetupCommunication, ReadVar, WriteVar, UserData, SZL, Blocks, BlockUpload, BlockDownload, PIService, Clock, Security, Programmer, Cyclic, Alarm}
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
- [Telemetry](docs/telemetry.md)
- [Compatibility](docs/compatibility.md)
- [Interoperability evidence](docs/interoperability.md)
- [Device qualification](docs/qualification.md)
- [Release process](docs/releasing.md)
- [Security policy](SECURITY.md)
- [Changelog](CHANGELOG.md)
- [Roadmap to 1.0](docs/roadmap.md)

## Development

```bash
mix deps.get
mix ci
mix docs --warnings-as-errors
mix release.check
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
Write Var, SZL, block-directory, block transfer, CPU control, set-clock, session-password,
programmer, cyclic, and alarm services without malformed packets:

```bash
bash scripts/run_snap7_packet_check.sh
```

CI runs the packet check and retains its PCAP artifact for seven days.

Named PLCSIM Advanced and physical PLC runs use the safety-gated device harness.
It restores a reserved scratch DB range and produces an ExUnit log, tshark
decode, report, and hashed PCAP. Read [Device qualification](docs/qualification.md)
before setting the required `S7_QUAL_*` environment or enabling writes.

Run the scheduled long-form qualification locally with:

```bash
S7_SOAK_ITERATIONS=20000 mix soak
```

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
