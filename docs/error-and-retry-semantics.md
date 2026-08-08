# Errors And Retries

All public failures use `%S7.Error{}`. The fields `layer`, `operation`,
`reason`, and `code` are public control-flow data. `details` is diagnostic
context and may gain keys in minor releases.

## Error Layers

| Layer | Meaning |
| --- | --- |
| `:address` | Invalid or unsupported address |
| `:data` | Value conversion or range failure |
| `:tcp` | Socket, timeout, or endpoint failure |
| `:tpkt` | Invalid RFC 1006 framing |
| `:cotp` | Invalid or unexpected COTP message |
| `:s7` | Invalid S7 PDU or PLC-reported failure |
| `:client` | Lifecycle, queue, or API failure |

Raw PLC and operating-system codes are retained in `code` when available.
Unknown codes map to a stable general reason rather than creating atoms from
peer input.

## Connection Effects

A local validation error does not affect the connection. A valid PLC item
error also leaves the connection usable. Loss of framing, a transport timeout,
socket closure, or an ambiguous in-flight response disconnects the session so
that stale bytes cannot be associated with a later request.

## Retry Contract

The library never automatically retries a write whose bytes may have reached
the peer. After timeout or connection loss, the write outcome is indeterminate;
the application must verify state before deciding whether to retry.

Automatic reconnect is opt-in. Reconnect restores a session but does not replay
the request that caused disconnection. Reads may be retried by an application,
or by a future explicit policy that preserves the same deadline and documents
the additional load.

## Multi-Item Contract

Multi-item responses preserve input order and retain each PLC return code in
`%S7.Result{}`. Packing several user items into multiple PDUs is not atomic.
The result statuses distinguish:

- completed successfully;
- rejected by the PLC;
- sent with an indeterminate outcome;
- not attempted after an earlier transport failure.

Completed execution returns `{:ok, results}`, even when individual PLC items
were rejected. If execution stops at the transport or protocol level, the API
returns `{:error, error, results}`. No convenience API collapses an
indeterminate write into a normal error that appears safe to retry.
