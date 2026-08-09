# Security Policy

## Protocol Boundary

Classic S7comm over RFC 1006 does not provide encryption, peer authentication,
or message integrity. This library cannot turn TCP port 102 into a secure
channel. A network attacker able to observe or modify the connection may read
process data, alter writes, impersonate a PLC, or terminate sessions.

S7comm-plus security mechanisms, TLS gateways, VPNs, and PLC access-control
configuration are outside the implementation boundary of this package.

## Deployment Requirements

- Place PLC networks behind firewalls and explicit allowlists. Do not expose
  TCP port 102 to the public internet.
- Restrict the application host to the PLCs and operations it needs. Separate
  monitoring-only deployments from deployments permitted to write.
- Use vendor-supported secure communications or a trusted network security
  layer when traffic crosses an untrusted boundary.
- Configure modern PLCs deliberately for classic PUT/GET access and
  non-optimized data blocks. Do not weaken unrelated PLC protections.
- Treat every write timeout or session loss as indeterminate. Verify process
  state before deciding whether an operational write may be retried.
- Keep `allow_destructive` disabled on monitoring and normal process-data
  clients. Use a separate least-privilege maintenance connection when block or
  CPU control is required.

## Library Controls

The client bounds TPKT input, receive buffering, COTP fragments, negotiated PDU
size, in-flight jobs, queued callers, request time, reconnect delay, reconnect
attempts, and graceful-drain time. Invalid framing disconnects the session so
stale bytes cannot be correlated with later work. Reconnect never replays work
from a failed session.

Telemetry excludes addresses, values, payloads, TSAPs, and credentials. Avoid
adding those fields in application handlers, logs, exception reports, or packet
captures. PCAP files contain process traffic and must be handled as sensitive
operational data.

Uploaded block images can contain proprietary control logic, symbols, comments,
and operational details. Treat both `%S7.BlockImage{}` values and raw upload
binaries as sensitive program material; do not emit them through telemetry,
logs, exceptions, fixtures, or public packet captures.

Block download, replacement, and deletion can stop a process, alter control
logic, or leave a passive image on the PLC even when activation fails. These
APIs require both `allow_destructive: true` when opening the connection and an
operation-specific confirmation atom on every call. Those controls reduce
accidental invocation; they are not authorization, authentication, rollback,
or a safety system. The library never retries a destructive operation after an
ambiguous outcome.

CPU stop/start, RAM-to-ROM copy, and memory compression use the same policy.
Run them only through a dedicated maintenance connection and verify CPU mode
and process state independently before and after each operation.

## Session Passwords

`S7.Client.authenticate/2` implements the classic protected-session exchange,
not a secure authentication protocol. Its wire transformation is reversible,
so anyone who can observe the connection can recover the password. Use it only
inside the protected network boundary described above.

Passwords are validated before queueing, redacted from Elixir inspection,
errors, and telemetry, and never stored for reconnect. Credential-bearing
requests are deliberately excluded from committed golden fixtures. The BEAM
uses immutable binaries, so neither the caller's password nor its transformed
request can be reliably zeroed in memory. Load credentials at runtime, keep
their lifetime short, and do not hard-code them in source, tests, logs, crash
reports, or packet captures.

## Reporting A Vulnerability

Report vulnerabilities privately through GitHub Security Advisories for the
repository. Include affected versions, impact, reproduction steps, and any
suggested mitigation. Do not include live PLC addresses, credentials, process
values, or production packet captures in a public issue.

Before a 1.0 release, security fixes are provided on the current main branch.
The supported release range will be listed here once stable releases exist.
