# Releasing

The repository may produce a Hex release candidate before hardware
qualification, but a stable 1.0 release requires every applicable row in
`docs/interoperability.md` to contain current evidence.

## Release Gates

1. Update `CHANGELOG.md`, package version, compatibility matrix, and protocol
   support status.
2. Run `mix release.check` from a clean checkout.
3. Run the 20,000-operation soak and pinned Snap7 packet check.
4. Complete PLCSIM Advanced and physical PLC qualification for every support
   claim with `scripts/run_device_qualification.sh`; record CPU, firmware,
   configuration, revision, date, and capture hash. Complete the separate
   destructive-service procedure on dedicated hardware where applicable.
5. Review `SECURITY.md`, dependency-audit output, generated docs, and unpacked
   Hex contents.
6. Tag the exact version as `vVERSION`. The release workflow rejects a tag that
   differs from `mix.exs`.
7. Review the workflow package and documentation artifacts before manually
   publishing with `mix hex.publish`.

## Local Commands

```bash
mix release.check
S7_SOAK_ITERATIONS=20000 mix soak
bash scripts/run_snap7_packet_check.sh
# Set the required S7_QUAL_* environment described in docs/qualification.md.
bash scripts/run_device_qualification.sh
```

`mix release.check` runs dependency audit, tests, coverage, static analysis,
Dialyzer, architecture checks, documentation generation, package inspection,
and exact Hex archive construction. It does not require Hex credentials and
never publishes.

The device command is intentionally not part of public CI. It requires a
reserved scratch DB and an exact write-confirmation value, retains its PCAP and
test log under `tmp/`, and fails if the configured CPU identity differs from
what the PLC reports. See `docs/qualification.md` before running it.

The tag workflow also runs the Snap7 packet gate and uploads the package, docs,
and PCAP as review artifacts. Hex publication remains a deliberate manual step
until signed/provenance-aware publishing is configured.
