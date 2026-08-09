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
| Common userdata envelope and request routing | Implemented | Supported |
| Userdata diagnostics/services | Not implemented | Post-1.0 |
| Block upload/download | Not implemented | Separate opt-in surface |
| PLC control | Not implemented | Separate opt-in surface |
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
and S7 session and never replays work from the failed session.

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
