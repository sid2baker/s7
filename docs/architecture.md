# Architecture

S7 is a classic S7comm client. Its runtime owns connections and request
lifecycle, while every wire codec remains independently usable as a pure
function.

## Layers

```text
S7 + focused service modules
    |
S7.Connection
    |
S7.Protocol.*
    |
S7.Transport.*
```

Value and addressing modules are shared models, not runtime services. Related
public values use domain-owned names:

```text
S7.Address       S7.Block.Info    S7.Alarm.Event
S7.Data          S7.PLC.Status    S7.Cyclic.Subscription
S7.Error         S7.Result        S7.TSAP
```

Every source file contains a primary module matching its module path. Tightly
owned child record types may remain in that primary module's file. A struct is
used when public callers or the runtime benefit from a named contract and
pattern matching; private one-service continuation state uses typed maps
instead of standalone modules.

`S7.Telemetry` is a one-way observability boundary used by the runtime. Protocol,
transport, and model modules cannot depend on it, so wire codecs remain pure.

The public API is deliberately small and grouped by workflow:

```text
S7              lifecycle and memory access
S7.PLC          metadata, clock, status, and CPU maintenance
S7.Blocks       block inventory and transfer
S7.Cyclic       cyclic subscriptions
S7.Alarm        alarm subscriptions, queries, and acknowledgments
S7.Programmer   read-only programmer services
S7.Session      classic session authorization
```

The following dependency rules are enforced by Reach through `.reach.exs`:

- Public API modules validate user input and delegate lifecycle work to the
  runtime. Advanced operations are not duplicated on `S7`.
- `S7.Connection` is the only layer allowed to own or operate a TCP socket.
- `S7.Protocol.*` may use value and address models but never the runtime.
- `S7.Transport.*` knows only RFC 1006 and COTP wire structures.
- Model modules do not depend on transport, protocol, or runtime modules.
- `S7.Telemetry` depends on none of the application layers; only the runtime emits through it.

## Runtime Ownership

One connection process owns one socket. A request is complete only after its
response has been correlated by PDU reference and fully validated at every
layer. No caller receives the socket or mutable connection state.

The runtime uses `active: :once` socket delivery and maintains bounded state
for:

- incremental TPKT bytes;
- COTP fragment reassembly;
- queued requests;
- in-flight requests indexed by PDU reference;
- request timers and caller monitors;
- one exclusive transaction with total, per-step, byte, message, and inbox bounds;
- monitored userdata subscriptions with pull or owner-message delivery.

Each logical multi-item operation has at most one PDU batch in flight. Different
callers may run concurrently up to the conservative minimum of the requested
and peer-returned AMQ limits. The default request remains one concurrent job.
Callers above that limit enter a bounded FIFO queue.

Protected-session login and logout are queue barriers. They wait for every
earlier correlated job, run alone, and prevent later work from overtaking the
authorization transition. Queue admission remains bounded while the barrier
is waiting or in flight. The runtime stores only the last confirmed
authenticated state; session loss clears it and reconnect never reuses a
credential.

Stateful services reserve the connection through an internal exclusive
transaction boundary. Existing ordinary jobs finish before ownership is
granted; later jobs remain queued until ownership is released. The owner may
send correlated Job PDUs, receive bounded Job PDUs initiated by the PLC, and
reply with Ack/AckData PDUs. Caller death, an overall deadline, an inbox
overflow, or an incoming traffic-limit violation closes the session because
the remote transaction state can no longer be established safely.

Block upload is the first typed service on this boundary. It reserves the
connection for the complete Start/Upload/End sequence and validates each
correlated response before advancing. An initial PLC rejection is a complete
outcome and releases ownership. A local byte or fragment limit sends End Upload
before release; malformed, timed-out, disconnected, or otherwise ambiguous
mid-sequence outcomes abort the transaction and invalidate the session.

Block download uses the bidirectional side of the same boundary. After the
initial correlated request, PLC-initiated Download Block and Download Ended
Jobs enter the bounded transaction inbox. The owner validates identity,
direction, sequence, and reference uniqueness before replying. Download data
responses are sized from the negotiated S7 PDU limit. `_INSE` activation stays
inside the reservation, so ordinary requests cannot observe a half-finished
local transaction. Deletion is also serialized through a short exclusive
PI-Service transaction.

CPU stop/start and maintenance controls use the same short exclusive-request
runner as deletion. This prevents ordinary work from overtaking a state change,
adds operation and step deadlines, and centralizes complete-rejection versus
indeterminate-outcome handling.

Destructive authority is immutable connection configuration and defaults off.
The public facade additionally requires an exact confirmation atom for every
download, replacement, deletion, and control call. Reconnect preserves only
the configured capability; it never replays the operation that lost its
session.

Unsolicited userdata indications never enter PDU-reference correlation. They
are routed by group, subfunction, and type to monitored subscriptions. Internal
one-shot programmer jobs use a bounded pull queue. Established cyclic and alarm
subscriptions decode in the connection process and send
`{:s7, reference, event}` directly to their owner. A decode or session failure
uses `{:s7, reference, {:error, error}}`. Session loss terminates all
subscriptions; a new session requires explicit resubscription.

An indication accepted by a subscription does not consume an unrelated
exclusive transaction's aggregate message budget. The connection does not add
a second queue in front of an owner mailbox; applications that need rate
control should subscribe from a dedicated process. Unmatched indications
remain visible through telemetry and do consume the transaction budget while
an exclusive transaction is active. Remote-backed cyclic and alarm
subscriptions additionally mark the session as dependent on their owner;
owner death closes the session so the PLC cannot retain an orphaned job or
message subscription. Alarm acknowledgments use a short exclusive transaction
so complete PLC rejection, local non-transmission, and an indeterminate
post-send outcome remain distinguishable.

The same connection PID may own a sequence of sessions. Opt-in reconnect uses
bounded exponential backoff with jitter, but first fails all work belonging to
the lost session. No PDU or logical operation crosses a session boundary.
Supervisors can start the client through `S7.start_link/1`; optional
registration uses the standard local, global, or `:via` forms.

Graceful close enters `:draining`, rejects new work, and finishes work already
accepted by the queue, including an active exclusive transaction. A bounded
drain timeout closes the socket and returns structured failures rather than
leaving callers blocked. Immediate and completed drain closes enter
`:disconnecting`, send COTP DR, and wait for DC or TCP FIN until the close
timeout forces socket closure.

## Protocol Invariants

- Decoders accept arbitrary binaries and return tagged results; malformed peer
  input must not raise.
- Encoders receive validated internal structures and may reject programmer
  errors before any bytes are sent.
- Request and worst-case response sizes must fit the negotiated S7 PDU size.
- TCP segmentation and TPKT boundaries are unrelated.
- COTP reassembly is bounded by negotiated and configured limits.
- A PDU reference is never reused while a request carrying it is in flight.
- Service decoders validate ROSCTR, PDU reference, header errors, parameters,
  item count, transport size, encoded length, and trailing bytes.

## Extension Boundaries

Additional classic services belong in the existing service-codec namespace and
use the TPKT/COTP stack. S7comm-plus is a different protocol and will not be
added to this namespace. A future plus implementation may reuse transport
modules only after a second consumer proves that extraction is useful.
