# Roadmap To 1.0

Each milestone is committed only after its tests and the existing `mix ci`
suite pass.

| Milestone | Outcome | Status |
| --- | --- | --- |
| 1 | Public contract and enforced architecture | Complete |
| 2 | Codec, lifecycle, and malformed-input hardening | Complete |
| 3 | Fixed-count addresses, arrays, and raw ranges | Complete |
| 4 | Multi-item codecs and exact PDU planning | Complete |
| 5 | Asynchronous request correlation and bounded concurrency | Complete |
| 6 | Supervision, reconnect, and safe recovery | Complete |
| 7 | Telemetry, security, interoperability, and soak tests | Complete |
| 8 | Hex, ExDoc, compatibility matrix, and release gates | Complete |

## Classic Extensions

| Milestone | Outcome | Status |
| --- | --- | --- |
| 9 | Class-0 COTP sizing, segmentation, and DR/DC/ER codecs | Complete |
| 10 | Generic userdata envelope and bounded request routing | Complete |
| 11 | Raw SZL continuation and typed CPU metadata | Complete |

Additional programmer diagnostics may follow. Block operations and PLC control
require separate opt-in APIs because their operational risk differs from
reading memory. S7comm-plus remains outside the current roadmap.
