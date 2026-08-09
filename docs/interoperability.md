# Interoperability Evidence

Support claims are tied to reproducible targets. Passing against one S7 peer
does not imply support for another CPU family, firmware line, simulator, or PLC
security configuration.

## Automated Matrix

| Target | Evidence | Frequency | Status |
| --- | --- | --- | --- |
| In-process fault server | TCP/COTP fragmentation, malformed frames, out-of-order responses, concurrency, timeout, reconnect, drain | Every commit | Passing |
| Snap7 server | `valiot/snap7` commit `a1845454f5f16f3b127b987807f1cbc59205db70` | Every commit | Passing |
| Wireshark/tshark | Pinned netshoot image; Setup, Read/Write Var, SZL, block, clock, and security-service filters; zero malformed frames | Every commit | Passing |
| Request soak | 20,000 mixed concurrent reads/writes with bounded memory and empty final mailbox | Weekly/manual | Automated |

The Snap7 gate negotiates four jobs, exercises concurrent reads, all supported
areas and scalar types, counted values, raw access, multi-item operations, PDU
splitting, read-after-write, block inventory, DB listing, and DB metadata. The
gate also sets the server clock and performs protected-session login/logout.
Read-clock decoding uses an independently captured PLC response because the
pinned Snap7 server emits a zero-based weekday that violates the Siemens
timestamp codec. The generated PCAP is retained by CI for seven days, and
Wireshark must identify all three block functions plus set-clock and password
services.

## Release Qualification Matrix

| Target | Required before claim | Current evidence |
| --- | --- | --- |
| PLCSIM Advanced | Full read/write suite and clean PCAP | Unverified |
| S7-300/400 family | Full suite on named CPU/firmware and clean PCAP | Unverified |
| S7-1200 family | Full suite on named CPU/firmware and clean PCAP | Unverified |
| S7-1500 family | Full suite on named CPU/firmware and clean PCAP | Unverified |

For each physical or simulated target, record CPU order number, firmware,
security/access configuration, rack/slot, negotiated PDU and AMQ values,
supported address areas, test revision, capture hash, and date. Packet captures
must be sanitized and handled according to `SECURITY.md`.

## Commands

```bash
mix ci
bash scripts/run_snap7_integration.sh
bash scripts/run_snap7_packet_check.sh
S7_SOAK_ITERATIONS=20000 mix soak
```

PLCSIM and physical PLC qualification remain explicit release gates rather
than normal public CI because they require licensed or dedicated hardware.
