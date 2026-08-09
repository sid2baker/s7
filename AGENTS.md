# S7 Contributor Instructions

S7 is a classic S7comm client. Keep changes evidence-based, bounded, and compatible
with the public API and wire contracts documented in this repository.

## Read First

- Read `docs/architecture.md` before changing dependencies between layers or the
  connection runtime.
- Read `docs/classic-completion.md` before adding or changing a protocol service.
- Read `docs/error-and-retry-semantics.md` before changing failures, retries,
  cancellation, reconnect, or connection effects.
- Use `docs/protocol-support.md` and `docs/interoperability.md` for support claims.
- Consult `resources/` when it exists locally. It is intentionally ignored and must
  never be staged or committed; tracked documentation and fixtures must remain
  sufficient to understand and verify the implementation.

## Architecture

- Keep `S7` as the sole public facade and `S7.Connection` as the only owner and
  operator of TCP sockets. Do not add a `S7.Client` compatibility module.
- Keep `S7.Protocol.*` and `S7.Transport.*` codecs pure and independently usable.
  They must not depend on the connection runtime or telemetry.
- Keep transport limited to RFC 1006/TPKT and COTP. Classic S7 service codecs belong
  under `S7.Protocol.*`.
- Preserve the model and telemetry dependency boundaries enforced by `.reach.exs`.
- Do not add S7comm-plus to the classic protocol namespace. Treat it as a separate
  protocol and introduce shared transport abstractions only after a real second
  consumer demonstrates the need.

## Code Organization

- Use domain-owned public names such as `S7.Block.Info`, `S7.Alarm.Event`, and
  `S7.PLC.Status`. Dots express ownership; do not split every word into another
  namespace level.
- Keep structs for stable public values, distinct wire packets, and runtime records
  whose identity is actively pattern-matched. Use maps or tagged tuples for private,
  one-service bookkeeping that does not need a module identity.
- Give every source file a primary module matching its module path. Keep a
  tightly owned child record, such as `S7.Cyclic.Event.Item`, in its parent's
  file; do not create empty namespace modules or namespace-only bundle files.
- Prefer the existing public facade and domain vocabulary over compatibility aliases,
  pass-through wrappers, or speculative abstractions.

## Protocol Work

- Never guess a wire layout. Follow the evidence ranking and clean-room requirements
  in `docs/classic-completion.md` before implementing bytes.
- Do not transliterate GPL or LGPL reference code. Record independently derived wire
  notes and fixture provenance, then implement the Elixir codec independently.
- Decoders must accept arbitrary binaries and return tagged results. Malformed peer
  input must not raise or crash the connection process.
- Validate ROSCTR, PDU reference, header errors, parameter and data lengths, item
  counts, transport sizes, encoded lengths, sequence state, and trailing bytes where
  applicable.
- Respect negotiated PDU, AMQ, fragment, queue, message, byte, and timeout limits.
  TCP segmentation is unrelated to TPKT or COTP message boundaries.
- Return public failures as `%S7.Error{}` and preserve the documented distinction
  between complete rejection, not attempted, and indeterminate post-send outcomes.
- Codec support alone is not a PLC-family support claim. Update compatibility or
  support documentation only after the required interoperability evidence exists.

## Tests And Fixtures

- Add focused unit tests for every encoder, decoder, value conversion, and malformed
  input path changed.
- Golden fixtures must test both exact decoding and exact re-encoding. Keep their
  source, frame numbers, normalization, and hashes documented in
  `test/fixtures/README.md` or the applicable interoperability document.
- Add property coverage for encode/decode symmetry and arbitrary fragmentation when
  changing stream, TPKT, COTP, or reassembly behavior.
- Cover timeout, disconnect, cancellation, malformed response, and caller-death paths
  when changing runtime behavior.
- Run the narrowest relevant tests while iterating, then run `mix ci` before finishing
  a code change.
- Run `mix docs --warnings-as-errors` for public API or documentation changes. Run
  `mix release.check` for protocol surface, packaging, compatibility, or release work.
- Use `scripts/run_snap7_integration.sh` and `scripts/run_snap7_packet_check.sh` when a
  change affects generated packets or interoperability.

## PLC Safety

- Never run physical-device qualification without explicit user authorization, the
  required `S7_QUAL_*` configuration, and a reserved scratch DB range.
- Never enable destructive qualification, block replacement/deletion, or CPU control
  implicitly. Preserve immutable connection capability checks and exact per-call
  confirmation values.
- Never automatically retry state-changing or destructive operations after bytes may
  have been sent. Reconnect starts a new session and must not replay prior work.
- Keep credentials and secret-bearing payloads out of logs, telemetry, errors,
  fixtures, captures, and inspection output.

## VibeKit Quality Gate

```sh
mix deps.get
mix ci
```

- Keep changes small, tested, formatted, and consistent with existing modules.
- Treat `mix ci` as the full local validation suite: warnings, dependency audit,
  formatting, tests and coverage, Credo, Dialyzer, clone detection, and architecture
  checks.
