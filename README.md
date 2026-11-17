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

This part works today, on one machine, with one binary:

```console
$ hand run --inputs 'samples/*.txt' --outdir out -- ./transcode
job loc-be71930edc0e  shard 1-of-1  5 inputs
[1/5] take-01.txt                                  ok   538ms
[2/5] take-02.txt                                  ok   543ms
[3/5] take-03.txt                                  ok   505ms
[4/5] take-04.txt                                  ok   512ms
[5/5] take-05.txt                                  ok   535ms

done in 2.8s: 5 ran, 0 skipped
```

Every output is content-addressed (`out/1-of-1/take-01.txt.a9a37d340b74`), and every input is
checkpointed. So you can stop it however you want and run the same command again:

```console
$ # ctrl-c, kill -9, close the laptop, lose power
$ hand run --inputs 'samples/*.txt' --outdir out -- ./transcode
job loc-be71930edc0e  shard 1-of-1  5 inputs
resuming: 5 of 5 already finished in a previous run
[1/5] take-01.txt                                  skip (finished in a previous run)
...
done in 1ms: 0 ran, 5 skipped
```

Same command, same job id, no repeated work. That is the whole mechanism the distributed half is built
on.

## The part nobody else does

Kill it mid-job. Really kill it — hard terminate, no cleanup, no goodbye:

```console
$ hand run --inputs 'in/*.txt' --outdir out -- ./work &
$ kill -9 <hand>          # 4 of 12 inputs had finished
$ hand run --inputs 'in/*.txt' --outdir out -- ./work
job loc-3d11c7a8e209  shard 1-of-1  12 inputs
resuming: 4 of 12 already finished in a previous run
...
done in 8.1s: 8 ran, 4 skipped
```

The four finished inputs are **not** executed again — `scripts\proofs.ps1` asserts exactly that, and
that the journal replays with contiguous sequence numbers. The same guarantee is what the brain will
provide when *it* dies: work is checkpointed on the device that runs it, and handed on by expiring
lease. The brain is *allowed* to die. That is the whole design.

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
