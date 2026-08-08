# Compatibility

## BEAM Runtime

The supported CI matrix is:

| Elixir | Erlang/OTP | Role |
| --- | --- | --- |
| 1.17.3 | 26.2.5.21 | Minimum supported toolchain |
| 1.18.4 | 27.3.4.16 | Intermediate supported toolchain |
| 1.19.5 | 28.5 | Current supported toolchain |

`mix.exs` accepts Elixir `>= 1.17.0 and < 2.0.0`. A new Elixir or OTP major is
not supported until it has a green matrix entry. The library has one runtime
package dependency, `telemetry ~> 1.4`; development and test tooling is marked
`runtime: false`.

Linux is the primary CI platform. The runtime uses standard BEAM networking and
has no NIFs, but other operating systems remain community-tested until a CI job
is added.

## PLC Compatibility

Classic S7comm compatibility is evidence-based and independent from BEAM
compatibility. See `docs/interoperability.md` for exact automated targets and
the PLCSIM/physical PLC release matrix.

S7-1200 and S7-1500 CPUs generally require classic PUT/GET access and compatible
non-optimized data blocks. Optimized or protected symbolic access requires a
different protocol and is not inferred from successful classic S7ANY access.

## Versioning Policy

Before 1.0, minor releases may refine public option and result contracts but
will document migration impact. Starting with 1.0, removals or incompatible
semantic changes require a major release. New PLC families or data types are
not advertised solely because their wire shape appears compatible; each claim
requires the qualification evidence defined by this repository.
