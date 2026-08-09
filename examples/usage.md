# Usage Examples

These scripts are runnable from the repository checkout and use only the public
`S7` API. They default to rack `0`, slot `2`, TCP port `102`, and a five-second
timeout.

Before connecting, ensure that the PLC is reachable and permits classic S7comm
access. Absolute S7ANY access normally requires PUT/GET communication and a
non-optimized data block on newer Siemens CPUs.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `S7_HOST` | `127.0.0.1` | PLC hostname or address |
| `S7_PORT` | `102` | RFC 1006 TCP port |
| `S7_RACK` | `0` | PLC rack |
| `S7_SLOT` | `2` | PLC slot |
| `S7_TIMEOUT` | `5000` | Connect and request timeout in milliseconds |
| `S7_ADDRESS` | `DB1.DBW0` | Address used by single-read examples |

## Read One Value

```console
S7_HOST=192.168.1.10 mix run examples/read_value.exs
```

Select a different address with `S7_ADDRESS`:

```console
S7_HOST=192.168.1.10 S7_ADDRESS=MW10 mix run examples/read_value.exs
```

The script connects, performs a typed read, closes the connection in an
`after` block, and prints a structured `%S7.Error{}` message on failure.

## Read Multiple Values

`S7.read_many/2` retains one `%S7.Result{}` per input. The example prints each
item independently, including PLC item errors and indeterminate or
not-attempted statuses.

```console
S7_HOST=192.168.1.10 \
  S7_ADDRESSES='DB1.DBW0,MW10,IW0' \
  mix run examples/multi_read.exs
```

The client automatically splits a larger list according to the negotiated PDU
size and preserves input order when combining the responses.

## Inspect PLC Metadata

```console
S7_HOST=192.168.1.10 mix run examples/plc_metadata.exs
```

This reads connection limits, order code, CPU and communication-processor
information, operating status, PLC clock, and block counts. Not every CPU
supports every metadata request, so an individual operation error is printed
without preventing the remaining read-only queries.

## Run Under A Supervisor

```console
S7_HOST=192.168.1.10 mix run examples/supervised.exs
```

The script registers the client as `S7.Examples.PLC` and calls it by name. In an
application supervision tree, use a unique `:id` and `:name` for each PLC and
enable bounded reconnect when the process should survive an unavailable peer:

```elixir
children = [
  {S7,
   id: :packaging_plc,
   host: "192.168.1.10",
   name: MyApp.PackagingPLC,
   rack: 0,
   slot: 2,
   reconnect: true,
   reconnect_max_attempts: 20}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

The supervisor owns the child lifecycle. Do not call `S7.close/2` on a
permanent supervised child unless restarting it is the intended result.

## Write And Read Back

Only run writes against a designated scratch DB, marker, or output. The script
has no default write address or value, reads the old value first, then writes
and reads back. It intentionally leaves the requested value in the PLC.

```console
S7_HOST=192.168.1.10 \
  S7_WRITE_ADDRESS=DB1.DBW20 \
  S7_WRITE_VALUE=1234 \
  mix run examples/write_value.exs
```

`S7_WRITE_VALUE` accepts an integer or `true`/`false`. For signed values, REALs,
strings, arrays, and Siemens time types, construct an explicit `%S7.Address{}`
and pass the matching Elixir value to `S7.write/3`:

```elixir
temperature = %S7.Address{
  area: :db,
  db_number: 1,
  byte_offset: 20,
  data_type: :real
}

:ok = S7.write(MyApp.PackagingPLC, temperature, 12.5)
{:ok, 12.5} = S7.read(MyApp.PackagingPLC, temperature)
```

For an application using the released Hex package, add the dependency to
`mix.exs`:

```elixir
{:s7, "~> 0.1"}
```

Before the first Hex release, use the repository dependency:

```elixir
{:s7, github: "sid2baker/s7"}
```
