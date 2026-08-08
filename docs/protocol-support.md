# Protocol Support

This document distinguishes implemented behavior from the compatibility
contract targeted for `1.0`. A feature is supported only when its listed
interoperability targets have passed; decoding a capture alone is not enough.

## Transport

| Capability | Current | 1.0 target |
| --- | --- | --- |
| RFC 1006 / TPKT framing | Implemented | Supported |
| Partial and concatenated TPKT frames | Implemented | Supported |
| Bounded TPKT lengths | Implemented | Supported |
| COTP Connection Request/Confirm | Implemented | Supported |
| COTP Data TPDU reassembly | Implemented | Supported |
| COTP class | Class 0 | Class 0 |
| COTP Disconnect TPDU | TCP close only | Evidence-driven |

## S7 Services

| Capability | Current | 1.0 target |
| --- | --- | --- |
| Setup Communication | Implemented | Supported |
| Single Read Var | Implemented | Supported |
| Single Write Var | Implemented | Supported |
| Multi-item Read Var | Not implemented | Supported |
| Multi-item Write Var | Not implemented | Supported |
| Automatic PDU packing | Not implemented | Supported |
| Concurrent jobs | One job | Bounded by negotiation |
| SZL and CPU metadata | Not implemented | Post-1.0 |
| Userdata and diagnostics | Not implemented | Post-1.0 |
| Block upload/download | Not implemented | Separate opt-in surface |
| PLC control | Not implemented | Separate opt-in surface |
| Alarms | Not implemented | Post-1.0 |

S7comm-plus, secure PG/HMI sessions, and symbolic access to optimized data
blocks are outside this project's protocol boundary.

## Addressing And Values

The current client supports absolute S7ANY addresses in data blocks, inputs,
outputs, and markers. The scalar types are `:bit`, `:byte`, `:word`, `:dword`,
`:int`, `:dint`, and `:real`.

The `1.0` contract adds fixed-count values and raw byte ranges. String and
Siemens date/time types will be advertised only after golden captures and real
PLC tests exist for each representation.

## PLC Requirements

Classic absolute access depends on PLC configuration. In particular, modern
S7-1200 and S7-1500 targets generally require compatible PUT/GET access and
non-optimized data blocks. Classic S7comm is not encrypted. Applications must
provide network isolation and must not treat this library as a secure channel.

## Qualification Matrix

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
