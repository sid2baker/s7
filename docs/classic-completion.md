# Classic S7comm Completion Contract

This document defines what `S7` means by a complete classic S7comm client. The
protocol is not published as one complete normative specification, and Siemens
CPUs vary by family, firmware, protection level, and configured access. A
support claim therefore requires both a wire implementation and recorded
interoperability evidence.

## Completion Levels

The project tracks two independent completion levels:

1. **Codec complete** means every known envelope in scope can be decoded without
   losing unknown fields, encoded from a validated structure, bounded against
   hostile lengths, and tested against an independently sourced fixture.
2. **Client complete** means a typed public API owns the complete transaction,
   has documented lifecycle and retry semantics, and passes the applicable
   simulator or physical-device qualification.

A permissive decoder, a reference implementation, or one successful capture is
not sufficient for a client-complete claim.

## Scope

The `1.0` target is a general-purpose classic S7 PLC client for S7-300/400 and
the classic-compatible services exposed by S7-1200/1500 CPUs.

Included:

- RFC 1006, COTP class 0, and classic S7 PDU lifecycle;
- absolute variable access and standard PLC value representations;
- block inventory, information, upload, download, replacement, and deletion;
- raw SZL access and documented typed metadata;
- PLC clock and classic protected-session login/logout;
- CPU operating-state and maintenance control;
- programmer diagnostics and variable status where packet evidence exists;
- cyclic variable subscriptions;
- alarm subscription, query, indication, and acknowledgment;
- raw preservation and structured unsupported errors for CPU-specific variants.

Explicitly outside the core client:

- S7comm Plus and optimized symbolic access;
- SINUMERIK NC programming userdata group `0x3F`;
- firmware update and TIA hardware/project download formats;
- PLC server behavior;
- PLC-to-PLC PBC BSEND/BRECV userdata group `0x06`;
- PROFIBUS Data Record Routing userdata group `0x20`.

The generic userdata codec must still preserve the excluded groups and unknown
subfunctions without creating atoms from peer-controlled values. Dedicated
adapters may be added later without weakening the core support claim.

## Job Services

| Function | Code | Service | Risk | Target |
| --- | ---: | --- | --- | --- |
| Read Var | `0x04` | Single and multi-variable reads | Read-only | Implemented |
| Write Var | `0x05` | Single and multi-variable writes | State-changing | Implemented |
| Request Download | `0x1A` | Negotiate a block download | Destructive | Implemented; device qualification pending |
| Download Block | `0x1B` | PLC-driven block data transfer | Destructive | Implemented; device qualification pending |
| Download Ended | `0x1C` | Finish block transfer | Destructive | Implemented; device qualification pending |
| Start Upload | `0x1D` | Open a block upload session | Read-only | Implemented; device qualification pending |
| Upload | `0x1E` | Transfer one upload segment | Read-only | Implemented; device qualification pending |
| End Upload | `0x1F` | Close an upload session | Read-only | Implemented; device qualification pending |
| PI-Service | `0x28` | Insert/delete, warm/cold start, compress, copy RAM to ROM | Destructive | Implemented; device qualification pending |
| PLC Stop | `0x29` | Stop CPU execution | Destructive | Implemented; device qualification pending |
| Setup Communication | `0xF0` | Negotiate PDU and AMQ limits | Session | Implemented |

Block upload/download uses a stateful service and is not equivalent to Read Var
or Write Var. Download additionally requires the client to answer jobs initiated
by the PLC during an exclusive transaction.

## Userdata Services

| Group | Code | In-scope subfunctions | Target |
| --- | ---: | --- | --- |
| Programmer commands | `0x01` | Read-only block/variable status, stacks, and job inspection | Raw-first implementation complete; device qualification pending |
| Cyclic services | `0x02` | Subscribe, transfer, change-driven transfer, modify, unsubscribe | Planned |
| Block functions | `0x03` | List blocks, list by type, block information | Implemented; device qualification pending |
| CPU functions | `0x04` | Read SZL, message service, diagnostics, alarm query/ack/indications | SZL implemented; remainder planned |
| Security | `0x05` | Session password login/logout | Implemented; device qualification pending |
| PBC BSEND | `0x06` | Raw preservation only | Adapter scope |
| Time | `0x07` | Read/set clock | Implemented; following variants evidence-gated |
| Data Record Routing | `0x20` | Raw preservation only | Adapter scope |
| NC programming | `0x3F` | Raw preservation only | Excluded |

Programmer commands that force values, alter jobs, reset memory, or manipulate
breakpoints are destructive even though they use the userdata envelope. They
follow the same explicit authorization and no-retry rules as PLC control.

## Address And Value Target

The public address model must represent, when supported by S7ANY:

- data blocks and instance data blocks;
- process inputs, outputs, and markers;
- direct peripheral inputs and outputs;
- local data;
- S7 counters and timers.

The value layer must provide independently testable codecs for booleans,
signed and unsigned integers, 32/64-bit floating point, byte/word strings,
characters, classic `DATE`, `TIME`, `TIME_OF_DAY`, `DATE_AND_TIME`, and
`S5TIME`. Semantic codecs remain separate from transport-size selection so raw
access is always possible.

## Runtime Requirements

The connection process must support three request shapes:

- ordinary correlated request/response jobs;
- exclusive multi-PDU transactions such as upload and download;
- unsolicited indications routed to bounded monitored subscriptions.

Exclusive transactions prevent unrelated requests from interleaving. Every
transaction has a total byte limit, message limit, per-step timeout, overall
deadline, and deterministic cleanup. Caller death cancels local ownership but
does not make an ambiguous state-changing result safe to retry.

Graceful shutdown sends COTP Disconnect Request when possible, accepts
Disconnect Confirm or TCP FIN, and falls back to bounded socket closure. Peer
DR, DC, ER, FIN, RST, malformed TPKT, and truncated data remain distinct
structured failures.

## Safety Classes

| Class | Examples | Retry and authorization |
| --- | --- | --- |
| Read-only | Read Var, SZL, block inventory/upload, clock read | May restart only as a new transaction after session loss |
| State-changing | Write Var, clock set, alarm acknowledgment | No automatic retry after bytes may have been sent |
| Destructive | Download/delete block, stop/start, force, memory reset | Connection capability plus per-call confirmation; never replayed |
| Secret-bearing | Session login | Redacted from logs, telemetry, errors, fixtures, and inspection |

## Evidence Requirements

Evidence is ranked in this order:

1. Siemens semantic documentation for operation and record meaning;
2. independently corroborated wire layouts from PLC4X, Wireshark, and Snap7;
3. exact request/response or indication captures with frame numbers and hashes;
4. parser/encoder golden fixtures derived cleanly for this MIT project;
5. successful tests against the applicable PLCSIM or physical CPU family.

GPL/LGPL reference code is never transliterated. Wire notes and fixtures are
written first, then the Elixir codec is implemented independently.

## Definition Of Done

A milestone is complete only when:

- pure codecs reject malformed lengths, values, sequence changes, and trailing bytes;
- golden fixtures check decode and exact re-encode;
- property tests cover encode/decode and arbitrary TCP fragmentation where applicable;
- the fault PLC covers timeout, disconnect, malformed, and cancellation paths;
- public errors use `%S7.Error{}` and document connection effects;
- state-changing outcomes distinguish failed, indeterminate, and not attempted;
- generated traffic is decoded by Wireshark without malformed packets;
- relevant simulator/device rows in `docs/interoperability.md` are recorded;
- `mix release.check` passes from a clean worktree.

Unsupported CPU behavior is a valid structured result. It does not justify a
global support claim, and one CPU family's result is never inferred for another.
