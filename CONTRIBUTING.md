# Contributing

## Before you commit

```sh
make format       # swift-format over gui
make app-check     # gui swift-format lint --strict, build-app.sh syntax, Info.plist lint
make swift-lint swift-test verify-deps
```

CI runs all of these in one job. None of them need a Go toolchain — the Go reference implementation was
removed; see [docs/remove-go.md](docs/remove-go.md). The only thing that still wants Go is
`scripts/parity.sh`, a regression check against the last Go build (tag `go-reference-final`); see
[docs/parity-check.md#prerequisite-check-go-toolchain](docs/parity-check.md#prerequisite-check-go-toolchain)
for what to run instead when Go isn't available. Never install Go just to satisfy a check; its absence is a
valid environment.

## Changing the mutating core

Changing the slim engine (`Slim.swift`), `Live.swift`, `DisabledStore.swift`, `ProfileSave.swift`, or any
destructive command deserves extra care and, ideally, a parity run against the Go reference; see
[docs/parity-check.md](docs/parity-check.md).

See [CLAUDE.md](CLAUDE.md) for the full architecture notes and safety invariants.
