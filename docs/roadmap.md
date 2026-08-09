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

## Classic Completion

The exact scope and evidence rules are defined in
[`classic-completion.md`](classic-completion.md).

| Milestone | Outcome | Status |
| --- | --- | --- |
| 12 | Classic completion contract and service matrix | Complete |
| 13 | Remaining S7ANY areas and value representations | Complete |
| 14 | Runtime COTP DR/DC shutdown | Complete |
| 15 | Exclusive, bidirectional transactions and bounded push routing | Complete |
| 16 | Block inventory and block information | Complete |
| 17 | Clock and protected-session services | Complete |
| 18 | Bounded block upload and block-image parsing | Complete |
| 19 | Opt-in block download, replacement, and deletion | Complete |
| 20 | Opt-in PLC control | Planned |
| 21 | Raw-first programmer diagnostics and variable status | Planned |
| 22 | Cyclic subscriptions | Planned |
| 23 | Alarm subscription, query, and acknowledgment | Planned |
| 24 | Cross-family qualification and classic `1.0.0` release | Planned |

Every milestone is committed independently after its local and repository-wide
quality gates pass. Destructive operations additionally require dedicated test
hardware and a restorable PLC project. S7comm Plus remains outside this roadmap.
