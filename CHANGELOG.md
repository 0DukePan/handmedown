# Changelog

All notable changes to this project are documented here.

The format is [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). `0.x` versions make no compatibility
promises; the wire protocol carries a `v` field so the brain can refuse an agent it does not understand
instead of guessing.

## [Unreleased]

### Added

- Agent: `hand run [flags] -- <command>` — runs once per input, checkpointing each one, with
  `--inputs`, `--outdir`, `--shard i/n`, `--retries`, `--verbose`.
- Agent: append-only journal with fsync per record. Replay refuses a sequence gap, ignores a torn final
  line, and only counts records that carry a digest as finished work.
- Agent: content-addressed outputs (`<outdir>/<shard>/<name>.<sha256[:12]>`), committed with an atomic
  rename. A resume re-verifies each recorded digest instead of trusting the journal, so a deleted or
  edited output is redone rather than skipped.
- Agent: process runner that keeps the last 4 KB of each stream and reports exit codes as outcomes, not
  as errors.
- Proofs: `scripts\proofs.ps1` hard-terminates a real run mid-job and asserts that finished inputs are
  never executed twice, every input gets exactly one output, and the journal replays cleanly.
- Agent: `hand version`, subcommand dispatch, and a usage error that names the offending command instead
  of printing a wall of help.
- Brain: supervision root with a fleet process registry; `mix release` produces a runnable release.
- Tooling: `scripts\tasks.ps1` as the single task entry point, portable no-admin toolchains under
  `_bootstrap\`, CI across three OSes for the agent, release workflow emitting checksummed binaries.

### Changed

- `hand run` distinguishes "your tool failed" (exit 1) from "you called me wrong" (exit 2) and from
  an interrupt (exit 130).
- The README examples are now captured from real runs rather than written by hand; the aspirational
  distributed snippet moved to where it is clearly future work.

### Measured

Sizes are from a local Windows/amd64 build on 2026-11-17, because they are the argument, not decoration:

| Artifact | Size |
|---|---:|
| `hand.exe` (agent) | 2.40 MB |
| brain `mix release` | 111.7 MB |

The 46x gap is why the agent is Go: it has to run on a phone that already has an OS.

### Added

- Brain: `Handmedown.Schedule` owns every lease. 30 s TTL, 5 s sweep, retries until the attempt budget
  is spent, and requeue-on-lease-expiry. A device that disconnects loses its shards immediately rather
  than making the fleet wait for a timeout.
- Brain: durable state as a single atomically-rewritten JSON snapshot, so `kill -9` leaves either the
  old state or the new one and never a half-written file.
- Brain: dashboard (server-rendered HTML, pushed over SSE), `/api/jobs`, `/api/state`, `/health`, and a
  WebSocket endpoint for agents.
- Agent: `hand join` dials out to a brain, enrols, heartbeats, and runs whatever it is leased.
- Agent: `hand submit` expands inputs locally and posts a job - so a glob always means what the local
  runner would have meant by it.
- Agent: `hand version` now reports the build target; `hand run` is unchanged for local use.
- Proofs: `scripts\e2e.ps1` runs the whole loop with real processes, including killing the brain's VM
  and restarting it from disk.
- Correctness tests for the scheduler: expiry and requeue, duplicate completion accepted, **different
  digest marked `conflicted` and never resolved by picking a winner**, retry budget, and rebalancing.

### Notes

- There is no Makefile. `make` is not present on a default Windows install, and a task runner that only
  half the contributors can run is worse than none. Use `scripts\tasks.ps1`.
- v0.1 is single-brain by design; see `docs/DESIGN.md` for the single-writer constraint.
