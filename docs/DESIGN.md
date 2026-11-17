# Design

What `handmedown` guarantees, how, and where it stops guaranteeing anything.

## The claim

A shard survives **the death of the brain**, **the death of the agent**, and **the disappearance of the
device**. Best case, no work is repeated. Worst case, one lease interval (30 s) of *attempt* is
repeated. **Output is never corrupt and never duplicated.**

That is a narrower claim than "exactly once", deliberately. See [What is not guaranteed](#what-is-not-guaranteed).

## Two tiers

```
   device                        NAT / home wifi                  you
   +------------+                                            +----------------------+
   | hand agent |-- dials OUT, WebSocket, always ----------->|  brain (Elixir)      |
   |  (Go, ~7MB)|   heartbeat 5s, progress, journal digest    |  +----------------+  |
   |            |<-- lease + shard assignment --------------- |  | Scheduler      |  |
   |  +------+  |                                            |  | 1 proc/device  |  |
   |  |journal| |  checkpoint: seq, bytes, part digest        |  | leases, sweep  |  |
   |  +------+  |  output: out/<shard>/<part>.<hash> (rename)|  +----------------+  |
   +------------+                                            |  | JSON snapshot  |  |
                                                             |  | SSE + HTML     |  |
                                                             |  +----------------+  |
                                                             +----------------------+
```

The device's socket *is* its scheduler entry: the WebSocket handler process holds the connection and
is registered as the device, so "the device went away" is one `:DOWN` message and nothing to clean up.

## Decisions taken while building

Recorded because they differ from the original plan in
[repo-of-the-day-proposal-handmedown.md](../../repo-of-the-day-proposal-handmedown.md), and a design
doc that only agrees with the plan is not a design doc:

| Planned | Built | Why |
|---|---|---|
| Postgres or SQLite via Ecto | One JSON file, atomically rewritten | No C NIF means no compiler needed to run the brain; a snapshot is either old or new after a crash, with no repair step to reason about. v0.2 can swap in Postgres behind `Store` without touching the scheduler. |
| Phoenix LiveView dashboard | Server-rendered HTML pushed over SSE | LiveView needs a JS asset build; SSE needs 6 lines of client JS and no build step, which keeps "one command" true on a fresh machine. The rendering stays on the server, where the tests are. |
| Two brains clustered | One brain, documented as single-writer | The crash guarantee comes from the agent's journal and the leases, not from consensus. Clustering adds a coordination problem without adding a guarantee users can see. |
| `NodeSup`/`ShardSup` process trees | One process per device; shard execution on the device | Shards run on the device, so the brain tracks them as data with a deadline rather than as processes it must supervise. Fewer moving parts on the side that is allowed to die. |

**Agents dial out, always.** No inbound ports, no router configuration, works behind CGNAT, survives a
phone changing networks three times a day. This is also the honest answer to "why not Nomad": a Nomad
agent has to be reachable, and a phone in a drawer is not.

## Work model

A job names a command and a list of inputs. The agent owns splitting and completion:

| Mode | How you ask for it | Who splits | Resume granularity | Guarantee |
|---|---|---|---|---|
| **B — file list** (default) | `--inputs <glob\|file\|dir>` | agent | per input | full: finished inputs are skipped, and each recorded output is re-verified by digest before it is trusted |
| **A — single command** | no `--inputs`: `hand run -- <cmd>` | nobody | none | retry only: a failed run restarts the command |

`--shard i/n` slices the expanded list in mode B: contiguous, deterministic, and shared job id with
the other slices. `hand run --inputs '*.mov' --shard 2/3 -- ./tool` is "your third of the work".

Mode B runs the command once per input with this environment contract:

| Variable | Meaning |
|---|---|
| `HAND_INPUT` | absolute path to this input |
| `HAND_OUTPUT` | absolute path this run must write its result to |
| `HAND_INDEX` / `HAND_TOTAL` | 0-based index of this input, and the shard's input count |
| `HAND_JOB_ID` / `HAND_SHARD_ID` | stable ids, for logging |

The command exits non-zero and the input is retried (mode B, up to `--retries`). It exits zero and the
agent commits the output.

## The journal

Per shard: `.hand/journal/<job_id>/<shard_id>.jsonl`. Append-only, one JSON object per line, `fsync`
after every record (correctness over throughput; at these rates the cost is noise).

```json
{"seq":1,"op":"start","job":"j-7f3a","shard":"s-02","mode":"files","total":412,"ts":"2026-11-17T17:40:01Z"}
{"seq":2,"op":"item","key":"a.mov","out":"out/s-02/a.mov.9f2c1b7e4a01","digest":"sha256:9f2c1b7e4a01...","ts":"..."}
{"seq":3,"op":"done","items":412,"ts":"..."}
```

Replay rules, all covered by tests:

- The last line may be torn by a crash. It is ignored, not an error.
- `seq` must increase; a gap means the file was tampered with, and the shard refuses to resume rather
  than silently forget work.
- `item` with an existing output path whose content hashes to the recorded digest is skipped.
- Anything else is redone.

## The lease

The brain is the only authority. There is no consensus, no leader election, and no membership protocol,
because devices are not peers — they are unreliable clients.

| Property | Value |
|---|---|
| lease TTL | 30 s |
| heartbeat | 5 s |
| sweep | 5 s |
| requeue trigger | no heartbeat for 30 s, or explicit `revoke` |
| max attempts | 3, then the shard is `failed` and the job is `partial` |
| completion dedupe | `(job_id, shard_id)` — same digest ignored, **different digest → `conflicted`** |

A `conflicted` shard is surfaced in the dashboard and fails the job. It is never resolved by picking a
winner: two devices claiming different output for the same shard means the command is not deterministic,
and guessing would hide exactly the bug the user needs to see.

## Output

Every output is content-addressed: `<outdir>/<shard_id>/<basename>.<sha256[:12]>`, written to a
temporary name in the same directory and committed with an atomic `rename`. A retried input therefore
either overwrites its own part with identical bytes, or lands beside it under a different digest — where
the conflict check above catches it.

## What is not guaranteed

- **Exactly-once execution.** A retried input runs the command again. Side-effecting commands must be
  idempotent. Every scheduler ever built says this; the README says it too.
- **Ordering.** Inputs are independent. There are no dependencies between shards in v0.1.
- **Clock sanity.** Device clocks are untrusted. Timing is the brain's, in elapsed form; a device that
  reports a clock three days behind is still scheduled correctly, because nothing is ordered by its
  clock.
- **A single writer.** v0.1 runs one brain per database. Two brains against one state file is not
  supported and will corrupt state; clustering (v0.2) is a leader-and-standby design, documented when
  it exists.
- **A whole process tree on cancel.** Cancelling a shard terminates the command the agent started. A
  build tool that spawns grandchildren of its own can outlive that cancel on Windows, where there is no
  process group to signal. The journal still protects the work: a shard whose parent was cancelled is
  requeued, and any output the orphan went on to write lands under its own content address, where the
  digest check sees it. Tracked as a known gap, not an oversight.

## Known gaps

| Gap | Consequence | Why it is acceptable in v0.1 |
|---|---|---|
| Grandchild processes survive a cancel on Windows | A cancelled build may keep burning CPU briefly | The result is still correct; only the tidiness of the cancel is affected |
| Device clock skew | Progress timestamps on the dashboard can look out of order | Leases are computed on the brain, so scheduling is unaffected |
| A device that loses the brain mid-shard keeps working | Work continues on a lease the brain has already requeued | The journal makes the retry safe; at most one attempt's work is duplicated |
| No TLS, token auth only | Traffic is readable on the local network | Documented in `SECURITY.md`; LAN or Tailscale only |

## Budgets

| Budget | Target | Why it is a budget, not a wish |
|---|---|---|
| idle agent RSS | < 25 MB | it lives on a phone |
| `hand version` | < 20 ms | it is run by scripts and by `doctor` |
| brain cold start | < 2 s | restarting the brain must feel cheap during the crash demo |
| lease detection | ≤ 35 s | 30 s TTL + 5 s sweep, and the demo asserts it |

## Testing stance

Deterministic where it matters: the scheduler takes an injected clock, the sweep is called explicitly in
tests rather than waited for, and no unit test touches the network. Behavioural proofs (crash-resume,
lease expiry, digest conflict) live in `scripts/tasks.ps1` targets and are run against a real process
tree, because those are the claims the README makes.
