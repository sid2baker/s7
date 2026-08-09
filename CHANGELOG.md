# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog, and stable releases use Semantic Versioning.

## Unreleased

Changes currently targeted for `0.1.0` are listed below.

### Changed

- Extended the supported BEAM matrix through Elixir 1.20.3 and Erlang/OTP
  29.0.5, and moved quality, release, and soak CI to that toolchain.
- Moved the public facade from `S7.Client` to `S7`, without a compatibility
  module, so connection lifecycle and operations are available directly as
  `S7.connect/2`, `S7.read/2`, `S7.write/3`, and `S7.close/2`.
- Grouped public result types under their owning domains, including
  `S7.Block.Info`, `S7.Alarm.Event`, `S7.Cyclic.Event`, `S7.Programmer.Event`,
  and `S7.PLC.Status`.
- Co-located related models and wire packet types, and replaced private
  one-service transaction structs with typed maps to reduce source and module
  sprawl without changing protocol behavior.

## 0.1.0 - Unreleased Release Candidate

### Added

- RFC 1006 TPKT framing with fragmented and concatenated stream handling.
- COTP Connection Request/Confirm and bounded Data TPDU reassembly.
- S7 Setup Communication with negotiated PDU and AMQ limits.
- Absolute S7ANY addressing for DBs, inputs, outputs, and markers.
- Bit, byte, word, dword, int, dint, and REAL conversion.
- Scalar, counted, raw, and multi-item Read Var and Write Var operations.
- Exact PDU planning, automatic splitting, and partial/indeterminate results.
- Active-once request correlation, bounded concurrency, caller monitoring, and timeouts.
- OTP supervision, registered clients, bounded reconnect, and graceful drain.
- Telemetry, scheduled soak qualification, and security guidance.
- Golden packets, property tests, a fault-injection PLC, pinned Snap7 interop, and PCAP checks.
- Hex package metadata, ExDoc guides, a BEAM compatibility matrix, and release gates.
- Class-0 COTP segmentation plus Disconnect Request/Confirm and Error TPDU codecs.
- Generic classic userdata request routing with safe unsolicited-indication handling.
- Bounded raw SZL continuation, record validation, and typed CPU metadata helpers.
- Negotiation-aware COTP fragment bounds, control/userdata golden packets, and H-system metadata indexes.
- An explicit classic S7comm completion contract covering remaining services, safety classes, and evidence gates.
- Complete classic S7ANY area and transport-code modeling plus integer, floating-point, string, character, and Siemens temporal codecs.
- Bounded runtime COTP disconnect handshakes with peer DR acknowledgment and distinct DC, ER, FIN, and socket-error handling.
- Exclusive bidirectional transactions with deterministic ownership, traffic bounds, queued-work isolation, and drain integration.
- Bounded monitored routing for unsolicited userdata indications without weakening PDU-reference correlation.
- Bounded classic block inventory, list-by-type continuation, and detailed block metadata with capture-derived golden packets and Snap7/PCAP qualification.
- Timezone-free PLC clock read/set services and classic protected-session login/logout with strict queue barriers, credential redaction, and Snap7/PCAP qualification.
- Bounded classic block upload with exclusive lifecycle ownership, exact capture fixtures, raw image preservation, and structured load-memory image parsing.
- Opt-in classic block download, replacement, and deletion with negotiated PLC-driven slicing, exact STEP 7 fixtures, two-level destructive authorization, and explicit indeterminate outcomes.
- Opt-in CPU stop, warm/cold start, RAM-to-ROM copy, and memory compression with capture-derived codecs, exclusive no-replay execution, and Snap7/PCAP qualification.
- Raw-first read-only programmer diagnostics and variable-status sampling with capture-derived job setup, sequence-scoped indications, bounded exclusive execution, and deterministic remote-job deletion.
- Typed fixed-cycle and raw change-driven cyclic subscriptions with exact interval encoding, PLC-assigned job correlation, bounded owner-monitored queues, modification and remote teardown, capture-derived fixtures, and Snap7/PCAP qualification.
- Classic `ALARM_S` and `ALARM_8` setup, teardown, query, indication, and explicit acknowledgment with raw-preserving models, bounded owner-monitored queues, capture-derived fixtures, structured no-replay outcomes, and Snap7/PCAP qualification.
- A safety-gated cross-family qualification harness with exact CPU identity checks, scratch-range restoration, capability-specific tests, packet capture validation, and reproducible evidence reports.

The date remains unset until the external release qualification in
`docs/interoperability.md` is complete.
