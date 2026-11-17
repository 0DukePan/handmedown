# Security

## Threat model in one paragraph

`handmedown` runs on hardware you own, on a network you control. v0.1 assumes that network is trusted:
the agent-to-brain link is plain WebSocket with a shared join token. It is designed to be safe on a
LAN or over Tailscale, and it is **not** designed to be exposed to the internet. If you need that, put
it behind a reverse proxy that terminates TLS, and do not forward the port until v0.2 ships TLS.

## What is protected

| Concern | How |
|---|---|
| Who can join the fleet | A join token, generated per brain, required in the first `hello` frame; the socket is closed otherwise |
| What a token can do | Enrol a device and run jobs you submit from the brain. It cannot read the database or other devices' journals |
| Command execution | The agent runs exactly the command the brain sends, as the user who started it. That user already has the same power locally |
| Supply chain | Release binaries are published with `SHA256SUMS.txt`; the Windows installer refuses to install on a mismatch |

## What is not protected in v0.1

- **Transport is not encrypted.** Token and command lines are readable on the wire by anyone who can
  sniff your LAN. Use a trusted network or a tunnel.
- **No per-device authorisation.** One token enrols everything; there are no roles, no revocation UI
  (rotate the token in the config and restart).
- **No sandboxing.** An agent runs commands with its own privileges. `handmedown` is not a sandbox, a
  container runtime, or a defence against a malicious brain operator.
- **Journals are plain JSONL on disk**, readable by the user who ran the agent.

## Reporting

Open a private security advisory on GitHub, or email the maintainer listed in the repository profile.
Please do not open a public issue for anything exploitable.

Expect an acknowledgement within 48 h. There is no bug bounty; there is a credit line in `CHANGELOG.md`
if you want one.

## Rotating a token

```console
$ hand up --rotate-token       # prints a new join URL; existing agents must re-join
```
