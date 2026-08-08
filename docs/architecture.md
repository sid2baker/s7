# Architecture

S7 is a classic S7comm client. Its runtime owns connections and request
lifecycle, while every wire codec remains independently usable as a pure
function.

## Layers

```text
S7.Client
    |
S7.Connection
    |
S7.Protocol.*
    |
S7.Transport.*
```

The value and addressing modules are shared models, not runtime services:

```text
S7.Address  S7.Data  S7.Error  S7.Result  S7.TSAP
```

The following dependency rules are enforced by Reach through `.reach.exs`:

- `S7.Client` is the public facade and delegates lifecycle work to the runtime.
- `S7.Connection` is the only layer allowed to own or operate a TCP socket.
- `S7.Protocol.*` may use value and address models but never the runtime.
- `S7.Transport.*` knows only RFC 1006 and COTP wire structures.
- Model modules do not depend on transport, protocol, or runtime modules.

## Runtime Ownership

One connection process owns one socket. A request is complete only after its
response has been correlated by PDU reference and fully validated at every
layer. No caller receives the socket or mutable connection state.

The `1.0` runtime will use `active: :once` socket delivery and maintain bounded
state for:

- incremental TPKT bytes;
- COTP fragment reassembly;
- queued requests;
- in-flight requests indexed by PDU reference;
- request timers and caller monitors.

The current `0.1` implementation deliberately allows one blocking request at a
time. It will remain the reference behavior until the asynchronous request
engine passes the same interoperability tests.

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

Additional classic services belong under `S7.Protocol` and use the existing
TPKT/COTP stack. S7comm-plus is a different protocol and will not be added to
this namespace. A future plus implementation may reuse transport modules only
after a second consumer proves that extraction is useful.
