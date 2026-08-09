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
that stale bytes cannot be associated with a later request. Session loss fails
every in-flight and queued caller; each returned error retains that caller's
operation. A timed-out reference is never silently forgotten on a live socket.

When the configured caller queue is full, new work fails locally with
`:queue_full` and no bytes are sent. If a waiting caller exits, its queued work
is removed. If its PDU is already in flight, the response is still consumed and
correlated, but no additional batch is scheduled for that caller.

Login and logout are strict ordering barriers. Earlier jobs finish before the
authorization request is sent, later jobs remain in the bounded queue, and no
ordinary request is dispatched while the security request is in flight. A
confirmed login updates session state even if its caller exits after sending;
otherwise subsequent access decisions would be based on stale local state.
Logout or any session loss clears that state.

## Retry Contract

The library never automatically retries a write whose bytes may have reached
the peer. After timeout or connection loss, the write outcome is indeterminate;
the application must verify state before deciding whether to retry.

Automatic reconnect is opt-in. Reconnect restores a session but does not replay
the request that caused disconnection. Reads may be retried by an application,
or by a future explicit policy that preserves the same deadline and documents
the additional load.

Reconnect backoff has configurable minimum, maximum, jitter, and attempt cap.
Exhausting the cap leaves the stable client process in `:disconnected`; an
explicit `S7.Client.reconnect/1` starts a fresh attempt series. A successful
Setup Communication exchange resets the series.

Clock writes and protected-session changes are never retried automatically.
Clock values are timezone-free local civil time; applications own any UTC or
daylight-saving conversion before calling `set_clock/2`. A successful reconnect
does not reauthenticate because credentials are not retained.

Graceful close is also bounded. A drain timeout returns `:drain_timeout` to the
closing caller and every still-accepted operation, with each error's operation
field adjusted for its recipient. Once work is cancelled or drained, the
client sends COTP DR and accepts a matching DC or TCP FIN. A missing or invalid
confirmation only changes the internal disconnect diagnostic; the client
still force-closes the socket and returns `:ok` because its local close
postcondition has been met.

A peer DR is acknowledged with DC when its references match, then fails
pending work as `:remote_disconnect` while retaining the reason octet and
additional information. An unsolicited DC is
`:unexpected_disconnect_confirm`; COTP ER is `:protocol_error`; TCP FIN is
`:connection_closed`; other socket failures are `:tcp_error` with the original
reason in `code`.

SZL continuation is one logical request with fresh correlated PDU references
for each data unit. Fragment-count overflow, aggregate-size overflow, changed
data-unit identity, and malformed record geometry invalidate the session. This
prevents later work from sharing a connection with an abandoned server-side
userdata transaction. A PLC-reported SZL parameter error is complete and does
not invalidate the session.

Block-list continuation follows the same correlation and connection rules.
Changed data-unit identity, malformed four-byte entry geometry, fragment-count
overflow, or aggregate-size overflow invalidates the session. Block counts and
block information are fixed-size responses and reject continuation. A complete
PLC-reported directory error leaves the session usable.

Exclusive transactions are never replayed. A transaction has an overall
deadline, a per-request timeout, aggregate message and byte limits, and a
bounded inbox for PLC-initiated Jobs. An invalid owner/token or local option
failure sends no bytes. Owner death, overall timeout, inbox overflow, or an
incoming aggregate-limit violation closes the session because the peer may be
waiting for a service-specific continuation. A per-receive timeout leaves the
transaction owned and usable; the owner must either continue it or finish it.

Userdata subscriptions are session-local and pull based. A waiter timeout does
not remove its subscription. Queue overflow makes only that subscription
terminal with `:subscription_overflow`; the connection remains usable. Caller
death removes its subscriptions, while connection loss wakes all subscription
waiters and requires explicit resubscription after reconnect.

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
