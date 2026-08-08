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

## Reporting A Vulnerability

Report vulnerabilities privately through GitHub Security Advisories for the
repository. Include affected versions, impact, reproduction steps, and any
suggested mitigation. Do not include live PLC addresses, credentials, process
values, or production packet captures in a public issue.

Before a 1.0 release, security fixes are provided on the current main branch.
The supported release range will be listed here once stable releases exist.
