# Changelog

All notable changes to this project are documented here. The format follows
Keep a Changelog, and stable releases use Semantic Versioning.

## Unreleased

Changes currently targeted for `0.1.0` are listed below.

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

The date remains unset until the external release qualification in
`docs/interoperability.md` is complete.
