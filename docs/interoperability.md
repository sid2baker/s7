# Interoperability Evidence

Support claims are tied to reproducible targets. Passing against one S7 peer
does not imply support for another CPU family, firmware line, simulator, or PLC
security configuration.

## Automated Matrix

| Target | Evidence | Frequency | Status |
| --- | --- | --- | --- |
| In-process fault server | TCP/COTP fragmentation, malformed frames, out-of-order responses, concurrency, timeout, reconnect, drain | Every commit | Passing |
| Snap7 server | `valiot/snap7` commit `a1845454f5f16f3b127b987807f1cbc59205db70` | Every commit | Passing |
| Wireshark/tshark | Pinned netshoot image; Setup, Read/Write Var, SZL, block directory/transfer/control, clock, security, programmer, cyclic, and alarm-service filters; zero malformed frames | Every commit | Passing |
| Request soak | 20,000 mixed concurrent reads/writes with bounded memory and empty final mailbox | Weekly/manual | Automated |

The Snap7 gate negotiates four jobs, exercises concurrent reads, all supported
areas and scalar types, counted values, raw access, multi-item operations, PDU
splitting, read-after-write, block inventory, DB listing, and DB metadata. The
gate also sets the server clock and performs protected-session login/logout.
Read-clock decoding uses an independently captured PLC response because the
pinned Snap7 server emits a zero-based weekday that violates the Siemens
timestamp codec. The generated PCAP is retained by CI for seven days, and
Wireshark must identify all three block functions plus set-clock and password
services. The pinned Snap7 server does not implement block upload: the gate
requires its `0xD241` rejection to decode as `:access_denied`, verifies the
session remains usable, and requires tshark to identify Start Upload. Successful
Start/Upload/End assembly is qualified against an exact real-PLC capture and the
fault server; successful PLCSIM and physical-device execution remains pending.
The STEP 7 S7-300 download capture supplies an exact successful Request
Download, PLC-driven data response, Download Ended, and `_INSE` sequence. The
fault server repeats it with negotiated multi-PDU splitting and malformed-path
coverage. The pinned Snap7 server deliberately returns `0xD241` to Request
Download but accepts the generated `_DELE` envelope on its disposable target;
the gate verifies the session remains usable after both outcomes. The same
disposable server gate performs stop, warm start, cold start, RAM-to-ROM copy,
and memory compression, checks observable RUN/STOP transitions, and requires
tshark to identify every control service without malformed frames. Captured
STEP 7/Snap7 S7-300 exchanges provide independent golden bytes; PLCSIM and
physical-client execution remain pending. STEP 7 S7-300 captures also provide
the exact programmer-job setup, enable, indication, and delete envelopes for
variable status and block status v2. The fault server validates successful
sampling and cleanup. The pinned Snap7 server silently drops the programmer
request; the gate requires that wait to remain bounded and the ambiguous
session to be invalidated. The pinned Snap7 server also silently drops cyclic
setup. That gate likewise requires a bounded timeout, removal of the
provisional local subscription, and session invalidation; tshark must still
identify the emitted fixed-transfer request without malformed bytes. Exact
S7-400 WinCC captures qualify change-driven setup, modification, indication,
and teardown. The fixed-transfer fixtures are derived independently from the
pinned PLC4X grammar and Wireshark decoder because the local capture corpus has
no `0x01` exchange. PLCSIM and physical-device cyclic execution remain pending.
Exact WinCC S7-300 and S7-400 captures qualify alarm message setup/abort,
family and event queries, `ALARM_8`, and `NOTIFY` indications. The local corpus
has no acknowledgment exchange, so its request, response, and indication
fixtures are independently constructed from the pinned PLC4X grammar and
checked against the pinned Wireshark decoder. The fault server covers both
alarm families, ordered duplicate delivery, queue overflow, owner death,
queries, per-object acknowledgment errors, and ambiguous lifecycle outcomes.
The pinned Snap7 server returns a malformed message-service response to alarm
setup and explicit `0xD402` errors for alarm query and acknowledgment; the gate
checks those exact connection effects and requires tshark to identify all
three requests with no malformed frames. Successful alarm execution on PLCSIM
and physical devices remains pending.

## Release Qualification Matrix

| Target | Required before claim | Current evidence |
| --- | --- | --- |
| PLCSIM Advanced | Full read/write suite and clean PCAP | Unverified |
| S7-300/400 family | Full suite on named CPU/firmware and clean PCAP | Unverified |
| S7-1200 family | Full suite on named CPU/firmware and clean PCAP | Unverified |
| S7-1500 family | Full suite on named CPU/firmware and clean PCAP | Unverified |

The executable procedure is documented in
[`qualification.md`](qualification.md). Its core suite verifies negotiation,
exact target identity, typed/raw/multi/split process-data access, restoration of
the reserved scratch range, and a clean tshark decode. Capability-gated tests
cover SZLs, areas, blocks, upload, clock, session authorization, programmer
status, cyclic jobs, and alarms without pretending every CPU project exposes
every service. Destructive services use the separate dedicated-hardware
procedure in that guide.

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
# With the required S7_QUAL_* environment and reserved scratch DB:
bash scripts/run_device_qualification.sh
```

PLCSIM and physical PLC qualification remain explicit release gates rather
than normal public CI because they require licensed or dedicated hardware.
