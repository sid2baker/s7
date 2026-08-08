# Roadmap To 1.0

Each milestone is committed only after its tests and the existing `mix ci`
suite pass.

| Milestone | Outcome | Status |
| --- | --- | --- |
| 1 | Public contract and enforced architecture | Complete |
| 2 | Codec, lifecycle, and malformed-input hardening | Complete |
| 3 | Fixed-count addresses, arrays, and raw ranges | Planned |
| 4 | Multi-item codecs and exact PDU planning | Planned |
| 5 | Asynchronous request correlation and bounded concurrency | Planned |
| 6 | Supervision, reconnect, and safe recovery | Planned |
| 7 | Telemetry, security, interoperability, and soak tests | Planned |
| 8 | Hex, ExDoc, compatibility matrix, and release gates | Planned |

Classic SZL/userdata diagnostics may follow `1.0`. Block operations and PLC
control require separate opt-in APIs because their operational risk differs
from reading and writing memory. S7comm-plus remains a separate project.
