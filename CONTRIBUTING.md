# Contributing

The most useful thing you can do is break the promise. A reproducible `lost work` report on real
hardware is worth more than a feature.

## The two rules

1. **`hand run --local` must stay useful on one machine.** The brain is additive. A change that makes the
   agent depend on a live brain breaks the project's shape, not just a test.
2. **Claims live in `docs/DESIGN.md` before they live in the README.** If you cannot say precisely what
   is guaranteed and what is not, it is not ready to be read by strangers.

## Dev loop

```powershell
. ..\_bootstrap\env.ps1        # Go 1.27, OTP 29, Elixir 1.20 - no admin, nothing machine-wide
scripts\tasks.ps1 check        # gofmt, vet, test, format, compile -warnings-as-errors, test
scripts\tasks.ps1 fmt          # format both halves
```

`_bootstrap\` is fetched with `_bootstrap\fetch-toolchains.ps1`. If you already have the toolchains on
your PATH, `tasks.ps1` uses yours and never touches `_bootstrap`.

There is no Makefile on purpose: `make` is absent from a default Windows install, and a task runner that
only half the contributors can run is worse than none.

## Tests

- Unit tests are hermetic: no network, no wall clock. The scheduler takes an injected clock; the sweep is
  called explicitly instead of waited for.
- Behavioural proofs (`scripts\tasks.ps1 proof`) spawn real processes because they test claims about
  process death, which you cannot fake convincingly in-process.
- A bug fix comes with the test that fails on the old code. For correctness bugs, the journal fixture
  that reproduced it goes in `fixtures/` too.

## Commit style

`type(scope): summary` — `fix(agent): resume after torn journal line`, `docs: state the lease claim`.
One logical change per commit; every commit compiles and passes `check` on its own.

## Style

- Go: `gofmt`, `go vet`, errors wrap with `%w` and say what to do next.
- Elixir: `mix format`, no `String.to_atom/1` on anything that came off the wire.
- Prose: state the guarantee, then the limit. Never the other way around.
