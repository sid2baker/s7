# Device Qualification

The committed test suite proves codec and runtime behavior against fault-injection
servers, packet captures, and a pinned Snap7 revision. A support claim for a PLC
family additionally requires a named PLCSIM Advanced or physical-device run with
a clean packet capture. The device harness creates that evidence without placing
hardware credentials or packet data in the repository.

## Safety Boundary

`scripts/run_device_qualification.sh` writes to a caller-selected DB range. Before
running it:

1. Use an offline simulator or a PLC disconnected from machinery.
2. Reserve at least 64 bytes in a non-optimized test DB.
3. Back up the PLC project and the selected DB range independently.
4. Confirm that classic PUT/GET access is enabled where the CPU requires it.
5. Set `S7_QUAL_CONFIRM_WRITES=qualified_scratch_db` only after checking the
   endpoint, rack, slot, DB number, and offset.

The test preserves the original scratch bytes and restores them in an `on_exit`
callback. If the original session fails, it opens a fresh session for restoration.
That mechanism is a final safeguard, not a substitute for a backup.

The harness does not write outputs or automatically invoke block download,
replacement, deletion, CPU stop/start, RAM-to-ROM copy, or memory compression.
Those services require a dedicated restorable PLC project and the manual evidence
procedure below.

## Required Configuration

| Variable | Meaning |
| --- | --- |
| `S7_QUAL_HOST` | PLC or PLCSIM endpoint |
| `S7_QUAL_FAMILY` | `plcsim_advanced`, `s7_300`, `s7_400`, `s7_1200`, or `s7_1500` |
| `S7_QUAL_ORDER_NUMBER` | Exact order code expected from SZL `0x0011` |
| `S7_QUAL_FIRMWARE` | Expected observed version as `major.minor.patch` |
| `S7_QUAL_ACCESS` | Human-readable access/security configuration for the report |
| `S7_QUAL_DB` | Reserved non-optimized scratch DB number |
| `S7_QUAL_DB_OFFSET` | First byte of the reserved range |
| `S7_QUAL_CONFIRM_WRITES` | Must be exactly `qualified_scratch_db` |

Connection defaults are TCP port `102`, rack `0`, slot `2`, programming-device
TSAP, a 5-second timeout, and a 64-byte scratch range. Override them with
`S7_QUAL_PORT`, `S7_QUAL_RACK`, `S7_QUAL_SLOT`,
`S7_QUAL_CONNECTION_TYPE`, `S7_QUAL_TIMEOUT`, and
`S7_QUAL_SCRATCH_SIZE`. `S7_QUAL_INTERFACE` selects the host capture interface;
the default is `any`.

The core run always verifies connection negotiation, exact CPU identity, raw and
typed DB access, every v0.1 scalar type, multi-item access, PDU splitting, and
read-after-write restoration.

## Optional Capabilities

Set `S7_QUAL_CAPABILITIES` to a comma-separated list. Unknown names fail before a
connection is opened, which prevents a typo from silently weakening a run.

| Capability | Additional configuration and behavior |
| --- | --- |
| `areas` | Reads at least one input, output, marker, and peripheral address from `S7_QUAL_READ_ADDRESSES`, for example `IB0,QB0,MB0,PB0` |
| `szl` | Reads raw SZL data, CPU component information, and operating status |
| `cp_info` | Reads communication-processor limits from SZL `0x0131` |
| `blocks` | Lists blocks and checks `S7_QUAL_BLOCK_TYPE`/`S7_QUAL_BLOCK_NUMBER` |
| `upload` | Uploads and parses that configured block |
| `clock` | Reads the PLC clock |
| `clock_write` | Writes the observed clock value back and verifies it within one second |
| `security` | Authenticates with runtime-only `S7_QUAL_PASSWORD`, then logs out |
| `programmer` | Samples the scratch address through variable status |
| `cyclic` | Receives and tears down a fixed cyclic subscription; interval is `S7_QUAL_CYCLIC_INTERVAL` |
| `alarms` | Sets up, queries, and tears down `S7_QUAL_ALARM_TYPE` (`alarm_s` or `alarm_8`) |
| `alarm_event` | Waits 30 seconds for an externally triggered event and explicitly acknowledges it |

Declare only capabilities the target and loaded PLC project intentionally expose.
An unsupported service is useful compatibility evidence, but it is not a passing
claim for that capability. The security password is inherited by the test process
and is never copied into the generated report.

## Running A Qualification

Docker is required for the pinned tcpdump/tshark image. For example:

```bash
export S7_QUAL_HOST=192.168.10.20
export S7_QUAL_FAMILY=s7_1500
export S7_QUAL_ORDER_NUMBER='6ES7 515-2AM02-0AB0'
export S7_QUAL_FIRMWARE=3.1.0
export S7_QUAL_ACCESS='PUT/GET enabled; non-optimized DB; test VLAN'
export S7_QUAL_DB=65000
export S7_QUAL_DB_OFFSET=0
export S7_QUAL_CONFIRM_WRITES=qualified_scratch_db
export S7_QUAL_CAPABILITIES='areas,szl,blocks,upload,clock,programmer,cyclic'
export S7_QUAL_READ_ADDRESSES='IB0,QB0,MB0,PB0'

bash scripts/run_device_qualification.sh
```

The output directory defaults to
`tmp/qualification-FAMILY-UTC_TIMESTAMP`; override it with
`S7_QUAL_OUTPUT_DIR`. Each run contains:

- `qualification-report.md` with target metadata, revision, negotiated limits,
  test status, decoded-frame count, and capture hash;
- `exunit.log` with every selected, skipped, and failed test;
- `s7-qualification.pcap` with the exact exchange;
- `tshark-s7comm.txt` and `tshark-stderr.txt` with decoder evidence.

A run passes only when ExUnit succeeds, tshark decodes Setup Communication plus
Read Var and Write Var, at least one S7comm frame exists, and no captured frame is
marked malformed. The identity returned by the PLC must exactly match the
configured order number and version.

Packet captures can contain process values, block metadata, and reversible
classic passwords. Store and share them according to `SECURITY.md`; do not commit
raw qualification output.

## Destructive Qualification

Destructive services are qualified separately on a dedicated PLC with a verified
restore procedure. Record each operation, result, CPU state before and after,
frame numbers, and the sanitized capture hash in the applicable interoperability
evidence. At minimum, exercise:

1. Download a new reserved test block, upload it, and compare the exact image.
2. Replace that block, upload it again, and verify the replacement.
3. Delete only the reserved block and verify it is absent.
4. Stop and warm-start the CPU, checking state independently.
5. Cold-start the CPU where that family supports it.
6. Copy RAM to ROM and compress memory only where the test project and CPU mode
   make those operations recoverable.

Use a separate client opened with `allow_destructive: true` and the exact per-call
confirmation documented by `S7`. Never run this procedure against a live
process. A rejected, unavailable, or inapplicable service must be recorded as such
rather than converted into a passing result.

## Acceptance Record

For every row in `docs/interoperability.md`, retain the generated report and
sanitized evidence with CPU order number, firmware, access configuration,
rack/slot, negotiated PDU/AMQ/TPDU values, Git revision, UTC date, and capture
SHA-256. Do not change a row from `Unverified` until another person has reviewed
both the report and packet decode.
