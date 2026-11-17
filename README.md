<div align="center">

# handmedown

**Your old hardware is a cluster. Prove it in one command.**

![hand demo: an interrupted run, resumed, with nothing executed twice](docs/demo.gif)

`curl -fsSL https://raw.githubusercontent.com/0DukePan/handmedown/main/install.sh | sh`

_One binary. No YAML, no containers, no inbound ports, no account._

</div>

---

> **Status: v0.1 in progress.** The runner and the scheduler both work and are covered by proofs; the
> release and installers are prepared but no tag has been cut yet, so the one-liners above will only
> work once v0.1.0 is published. Binaries are **unsigned**: build from source if that matters to you.
> See [docs/DESIGN.md](docs/DESIGN.md) for what is proven and what is not.

## What it does

Your drawer has an old phone, a Raspberry Pi, and the laptop you replaced. `hand` turns them into one
machine that runs your `ffmpeg`, your test suite, your build — and keeps running when they sleep,
throttle, or die.

The GIF above is `hand demo`, and it is not a mock-up: it runs real work, interrupts itself, resumes,
and then checks that nothing ran twice. You can run it yourself.

![the dashboard, with a device holding two leased shards](docs/dashboard.png)

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

## Run it today

The agent is a single binary; the brain is an OTP release built from source.

```sh
# brain (Elixir 1.20 / OTP 29)
cd brain && mix deps.get && mix run --no-halt
# it prints the dashboard URL, a join command, and the join token

# device (Go 1.27) - on the phone in Termux, on the Pi, on the laptop
hand join --brain http://192.168.1.20:4100 --token <token from the brain>

# from anywhere
hand submit --brain http://192.168.1.20:4100 --token <token> \
  --inputs '*.mov' --shards 4 -- ./transcode --in "$HAND_INPUT" --out "$HAND_OUTPUT"
```

Then open the dashboard. Devices, shards, progress, digests, and which device holds which lease.

## Install

```sh
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/0DukePan/handmedown/main/install.sh | sh

# Windows
irm https://raw.githubusercontent.com/0DukePan/handmedown/main/install.ps1 | iex
```

Both verify the download against the release's `SHA256SUMS.txt` and refuse to install on a mismatch.
Neither needs root or an administrator; both land under your home directory.

**Termux (Android)** is the `linux/arm64` build — a phone is an ordinary Linux userland, so there is no
separate Android artefact:

```sh
pkg install curl
curl -fsSL https://raw.githubusercontent.com/0DukePan/handmedown/main/install.sh | sh
```

**No release yet?** Build from source: `scripts\tasks.ps1 build` (needs Go 1.27 and Elixir 1.20 / OTP 29;
`_bootstrap\env.ps1` fetches both without administrator rights). Binaries are unsigned.

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
scripts\tasks.ps1 proof       # hard-kill a local run and prove finished work is never repeated
scripts\tasks.ps1 e2e         # brain + agent + lease + completion + brain crash, with real processes
```

The two proof scripts are the honest version of the claims above: they spawn real processes, kill them
ungracefully, and check the state afterwards.

## License

AGPL-3.0. Use it, change it, self-host it. If you run a modified version as a service, share the
changes.
