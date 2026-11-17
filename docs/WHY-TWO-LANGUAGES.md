# Why two languages

Every "why is this two languages?" review ends one of two ways: the split was load-bearing, or it was
indecision. This file exists so the answer is readable before the code is.

## The test the split has to pass

Two languages in one repo is a cost: two toolchains, two dependency trees, two CI configurations, and
one more thing for a contributor to install. That cost is only worth paying when the halves have
**opposite requirements**. Not different features — opposite requirements.

`handmedown` passes that test:

| | agent (`agent/`, Go) | brain (`brain/`, Elixir) |
|---|---|---|
| Runs on | a 4 GB phone, a Pi, a laptop | one machine you own, ideally always-on |
| Must be | one small static binary, no runtime installed | a supervised, long-lived, hot-reloadable service |
| Failure mode | dies when the device sleeps, loses wifi, is closed | dies when you `kill -9` it or restart the box |
| What it does when it fails | resumes from its own journal on disk | adopts surviving shards from leases in its database |
| Concurrency model | a handful of processes, `exec` and I/O | one process per device, per shard, per job |
| Detection latency that matters | seconds (reconnect backoff) | milliseconds (a device vanished) |

The agent cannot be BEAM: an OTP release is tens of MB and needs the runtime present — a bad tenant on
a phone that also runs an OS. The brain cannot be Go, in the sense that matters: you would spend the
project rebuilding supervision, per-device processes, broadcast fan-out and a hot-reloadable control
plane, and you would do it worse than the runtime that ships the first three.

Measured in this repo on 2026-11-17 (Windows/amd64), because an argument with no numbers is an opinion:

| Artifact | Size | What it means |
|---|---:|---|
| `hand.exe` (agent, stripped) | <!-- size:agent -->7.10 MB<!-- /size:agent --> | one static binary, no runtime, cross-compiles to 6 targets |
| `mix release` (brain) | <!-- size:brain -->125.32 MB<!-- /size:brain --> | OTP included; must be installed where the brain runs |

A <!-- size:ratio -->17.6x<!-- /size:ratio --> difference. That is not a stylistic preference about languages; it decides what can be installed
on the device at the other end of the wire.

## The rule that keeps it honest

**v0.1 must be useful on a single machine.** `hand run --local` needs no brain. If the brain never
ships, this is still a resumable, content-addressed task runner. The second tier is additive, never a
prerequisite, and the whole system degrades to a good single-node tool.

If you are building something that fails this test — a CLI, a TUI, a proxy, a sync server for one
user — **do not do this**. Pick one language. This repo's shape is not a pattern to copy; it is a
consequence of placing work on hardware you do not control.

## Where the seam is, precisely

The seam is `ws://<brain>/ws`, protocol v1, JSON. It is deliberately dumb: no shared memory, no
RPC-by-function-name, no code generation, no Erlang distribution between the tiers. Either side can be
rewritten in another language without the other noticing — which is the real proof that the split is
architectural rather than incidental.

Erlang distribution is used *inside* the brain only (v0.2 clustering). It never reaches the device.

## What would make this wrong

- If devices were reliable, the brain could be a few hundred lines of Go and this repo would be
  over-engineered.
- If the unit of work were a container, Kubernetes or Nomad would be the honest answer.
- If the brain had to serve browser traffic at scale, the agent would still be Go, but the brain would
  be Elixir for a different reason (LiveView), and that reason belongs in the design doc, not here.

Each of those is a real future. None of them is this repo's shape today.
