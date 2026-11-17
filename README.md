<div align="center">

# handmedown

**Your old hardware is a cluster. Prove it in one command.**

`curl -fsSL https://handmedown.dev/install.sh | sh`

_One binary. No YAML, no containers, no inbound ports, no account._

</div>

---

> **Status: v0.1 in progress.** The local runner is real; the distributed half is being built in
> public. See [docs/DESIGN.md](docs/DESIGN.md) for what is proven and what is not yet.

## What it does

Your drawer has an old phone, a Raspberry Pi, and the laptop you replaced. `hand` turns them into one
machine that runs your `ffmpeg`, your test suite, your build — and keeps running when they sleep,
throttle, or die.

```console
$ hand run --shard 12 ./transcode -- *.mov
 36 shards -> 3 devices (16 cores)
 done 412 files in 3m41s   (this laptop alone: 21m06s)   5.7x faster, $0.00
```

## The part nobody else does

Kill the control plane mid-job:

```console
$ kill -9 $(pgrep -f 'hand brain')
$ hand up
 reattached in 240ms - 3 shards adopted by lease - 0 lost, 0 duplicated
```

Work is checkpointed on the device that runs it, and handed on by expiring lease. The brain is
*allowed* to die. That is the whole design.

## Install

```sh
# macOS / Linux
curl -fsSL https://handmedown.dev/install.sh | sh

# Windows
irm https://raw.githubusercontent.com/0DukePan/handmedown/main/install.ps1 | iex

# Android (Termux)
pkg install hand
```

On a second device, `hand join` with the token your brain prints. That is enrolment.

## What it does NOT do

- **No containers, no YAML, no scheduler DSL.** A job is a command and a way to split its inputs.
- **No inbound ports.** Agents dial out, so this works behind CGNAT and on mobile networks.
- **No exactly-once side effects.** Output is content-addressed and deduplicated; if your command has
  side effects, make it idempotent — as with every scheduler ever built.
- **No TLS and no auth beyond a join token in v0.1.** Run it on a LAN or over Tailscale, not on a
  public port. See [SECURITY.md](SECURITY.md).
- **No GPU pools, no model sharding, no cloud.**
- **No telemetry.** The binary talks to your brain and nothing else.

## How it stays correct

Leases (30 s), heartbeats (5 s), content-addressed outputs, idempotent completion. A shard survives the
death of the brain, the death of the agent, and the disappearance of the device: at most one lease of
lost *attempt*, zero corrupt output. The precise claim, and its limits, are in
[docs/DESIGN.md](docs/DESIGN.md).

## Why Go and Elixir?

Because the two halves fail in opposite ways: the agent must be a single-digit-MB binary with no
runtime (it has to run on a phone), and the brain must notice a vanished device in milliseconds and
supervise thousands of shards. [docs/WHY-TWO-LANGUAGES.md](docs/WHY-TWO-LANGUAGES.md) argues it
properly, including when *not* to do this.

## Develop

```powershell
_bootstrap\env.ps1            # put Go 1.27 and OTP 29 / Elixir 1.20 on this shell's PATH
scripts\tasks.ps1 check       # fmt, vet, test - both halves
```

## License

AGPL-3.0. Use it, change it, self-host it. If you run a modified version as a service, share the
changes.
