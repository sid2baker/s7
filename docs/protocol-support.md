# Protocol Support

This document distinguishes implemented behavior from the compatibility
contract targeted for `1.0`. A feature is supported only when its listed
interoperability targets have passed; decoding a capture alone is not enough.
The complete scope and risk policy are defined in
[`classic-completion.md`](classic-completion.md).

## Transport

| Capability | Current | 1.0 target |
| --- | --- | --- |
| RFC 1006 / TPKT framing | Implemented | Supported |
| Partial and concatenated TPKT frames | Implemented | Supported |
| Bounded TPKT lengths | Implemented | Supported |
| COTP Connection Request/Confirm | Implemented | Supported |
| COTP Data TPDU segmentation/reassembly | Implemented; bounded from negotiated sizes | Supported |
| COTP class | Class 0 | Class 0 |
| COTP DR/DC/ER codecs | Implemented with runtime peer/local disconnect handling | Supported after device qualification |

## S7 Services

| Capability | Current | 1.0 target |
| --- | --- | --- |
| Setup Communication | Implemented | Supported |
| Single Read Var | Implemented | Supported |
| Single Write Var | Implemented | Supported |
| Multi-item Read Var | Implemented | Supported |
| Multi-item Write Var | Implemented | Supported |
| Automatic PDU packing | Implemented | Supported |
| Concurrent jobs | Implemented, defaults to one | Bounded by negotiation |
| Raw SZL reads and bounded continuation | Implemented | Supported after device qualification |
| Order code, CPU/CP info, and PLC status | Implemented | Supported after device qualification |
| Block counts, list by type, and block information | Implemented with bounded continuation | Supported after device qualification |
| Read/set PLC clock | Implemented; timezone-free wire value retained | Supported after device qualification |
| Protected-session login/logout | Implemented with credential redaction and queue barriers | Supported after device qualification |
| Block upload and load-memory image parsing | Implemented with exclusive bounded transactions | Supported after successful device qualification |
| Block download and replacement | Implemented with PLC-driven PDU splitting and explicit destructive authorization | Supported after successful device qualification |
| Block deletion | Implemented through PI-Service with explicit destructive authorization | Supported after successful device qualification |
| PLC stop and warm/cold start | Implemented with explicit destructive authorization | Supported after successful device qualification |
| Copy RAM to ROM and memory compression | Implemented through PI-Service with explicit destructive authorization | Supported after successful device qualification |
| Common userdata envelope and request routing | Implemented | Supported |
| Exclusive bidirectional service transactions | Implemented, internal typed-service boundary | Supported |
| Bounded unsolicited userdata routing | Implemented, internal typed-service boundary | Supported |
| Userdata diagnostics/services | Not implemented | Post-1.0 |
| Alarms | Not implemented | Post-1.0 |

S7comm-plus, secure PG/HMI sessions, and symbolic access to optimized data
blocks are outside this project's protocol boundary.

## Runtime Lifecycle

The client supports OTP child specifications, registered connection workers,
caller cancellation by process monitoring, bounded graceful drain, and opt-in
reconnect with bounded exponential backoff. Close sends COTP DR when a session
exists, accepts DC or TCP FIN, and force-closes after the caller's timeout.
Peer DR is acknowledged before requests fail; unexpected DC, ER, FIN, and TCP
socket errors retain distinct structured reasons. Reconnect creates a new COTP
and S7 session and never replays work from the failed session. Stateful
services can reserve the connection for a bounded bidirectional transaction;
unsolicited userdata indications are isolated from reference correlation and
routed to bounded monitored subscriptions. Session login/logout is serialized
as a queue barrier: earlier jobs complete first and later jobs cannot overtake
the authorization change. Block upload runs exclusively and has independent
aggregate byte, fragment, step-timeout, and overall-deadline bounds.
Block download uses the same ownership boundary but handles Jobs initiated by
the PLC and splits response data against the negotiated PDU size.

## Addressing And Values

The client models absolute S7ANY addresses in data blocks, instance data
blocks, inputs, outputs, markers, direct peripherals, local and previous-local
data, counters, and timers. Counter and timer offsets are element numbers;
other offsets are byte/bit positions.

The pure value layer implements booleans, signed and unsigned 8/16/32/64-bit
integers, IEEE-754 binary32/binary64 values, byte and wide characters, fixed
Siemens STRING/WSTRING storage, DATE, TIME, TIME_OF_DAY, DATE_AND_TIME,
S5TIME, counters, and timers. Fixed-count values and raw byte ranges are
implemented for all non-bit types. Bit access remains scalar because reference
implementations and tested peers reject a bit transport amount greater than
one.

Semantic types and S7ANY transport sizes are separate. Native classic
date/time transport codes can be selected explicitly, while byte transport is
the compatibility default for representations whose native transport support
varies by CPU. Codec support does not imply device qualification; each area,
transport, and CPU-family combination remains subject to the matrix below.

Raw SZL records are returned without CPU-family assumptions. Typed metadata
helpers cover Siemens-documented module/component records plus the established
Snap7 CP-limit and operating-status layouts; raw source bytes remain available
for forward compatibility. Component metadata recognizes the packed rack and
master/reserve index used by S7-400H CPUs and retains each full 16-bit index.

Block inventory returns all advertised type counts, preserving unknown wire
types. Lists by type are assembled under caller-configurable aggregate byte and
fragment bounds. Detailed block information validates the requested identity,
fixed response geometry, and Siemens timestamps while preserving its complete
raw payload. Block upload is a separate stateful Job transaction. It validates
the requested identity, declared load-memory and MC7 sizes, timestamps, and
known footer fields while retaining the exact image. The raw API preserves
CPU-specific variants. Classic image MC7 and footer ranges can overlap, so the
model does not incorrectly treat them as disjoint sections. Download,
replacement, and deletion are separate destructive APIs. They are disabled by
default at connection creation and require a distinct confirmation atom on
every call. Raw images are fully parsed before transmission. Download covers
Request Download, bounded PLC-driven data pulls, Download Ended, and `_INSE`;
delete uses `_DELE`. No destructive request is automatically replayed.

Clock reads return a timezone-free `S7.PLCClock` with the complete ten-byte
timestamp. Clock writes accept millisecond-precision `NaiveDateTime` values.
The century hint is preserved but does not override the validated Siemens
two-digit-year pivot because observed devices encode the hint inconsistently.

Classic protected-session login accepts one to eight printable ASCII bytes.
It changes authorization only for the current S7 session and does not provide
encryption, integrity, or PLC authentication. Logout and every session loss
clear the client's authenticated state; reconnect never retains or replays a
password.

## PLC Requirements

Classic absolute access depends on PLC configuration. In particular, modern
S7-1200 and S7-1500 targets generally require compatible PUT/GET access and
non-optimized data blocks. Classic S7comm is not encrypted. Applications must
provide network isolation and must not treat this library as a secure channel.

## Qualification Matrix

The evidence and required report fields are maintained in
[`docs/interoperability.md`](interoperability.md).

| Target | CI | Release qualification |
| --- | --- | --- |
| In-process fault server | Every commit | Every release |
| Pinned Snap7 server | Every commit | Every release |
| PLCSIM Advanced | No | Every release candidate |
| Physical S7-300/400 family | No | Before claiming support |
| Physical S7-1200 family | No | Before claiming support |
| Physical S7-1500 family | No | Before claiming support |

Unexecuted hardware rows are reported as unverified rather than inferred from
another PLC family.
