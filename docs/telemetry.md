# Telemetry

`S7.Telemetry.events/0` returns every supported event name. Handlers use the
standard `:telemetry.attach_many/4` API. Duration and delay measurements use
native monotonic time units unless noted otherwise.

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:s7, :connection, :connected]` | `system_time`, `pdu_size`, `max_jobs` | `connection`, `host`, `port`, `reconnected` |
| `[:s7, :connection, :disconnected]` | `system_time` | `connection`, `host`, `port`, `error_layer`, `error_reason` |
| `[:s7, :connection, :reconnect_scheduled]` | `delay`, `attempt` | `connection`, `host`, `port` |
| `[:s7, :request, :queued]` | `system_time`, `queue_depth` | request metadata |
| `[:s7, :request, :rejected]` | `system_time`, `queue_depth`, `queue_duration` | request metadata plus `reason` |
| `[:s7, :request, :start]` | `system_time`, `queue_duration`, `request_size`, `in_flight` | request metadata |
| `[:s7, :request, :stop]` | `duration`, `request_size`, `response_size` | request metadata plus outcome fields |
| `[:s7, :userdata, :unhandled]` | `system_time`, `payload_size` | connection, reference, group, subfunction, sequence |

Request metadata contains `connection`, opaque `request_id`, `operation`, PDU
`reference`, batch `item_count`, and `raw`. Stop metadata adds `outcome`,
`item_error_count`, and, for failures, `error_layer` and `error_reason`.

One logical multi-item call may emit several start/stop pairs because each PDU
batch has its own reference, queue time, and wire duration. Queue and stop
events preserve the same opaque request ID across those batches.

The metadata contract intentionally excludes addresses, values, payloads,
source and destination TSAPs, and credentials. The authoritative exclusion list
is `S7.Telemetry.excluded_metadata/0`.

Example attachment:

```elixir
:telemetry.attach_many(
  "my-s7-metrics",
  S7.Telemetry.events(),
  &MyApp.S7Metrics.handle_event/4,
  nil
)
```
