# Contributing

## Before you commit

```sh
make format       # gofmt + swift-format
make check        # Go gate: go test, go vet (needs a Go toolchain)
make app-check    # gui swift-format lint --strict, build-app.sh syntax, Info.plist lint (no Go)
make swift-lint swift-test verify-deps   # Swift port gate (no Go)
```

CI runs all of these. `make check` needs a Go toolchain; the others do not. If Go isn't available, or you
only touched `swift/` or `gui/`, run the Go-free checks instead — see
[docs/parity-check.md#prerequisite-check-go-toolchain](docs/parity-check.md#prerequisite-check-go-toolchain)
for the exact commands for each case. Never install Go just to satisfy a check; its absence is a valid
environment.

## The Swift port

After changing `profiles.go`, `service_descriptions.go`, `features.go`, or `profiles_test.go`, run
`make swift-gen` and commit the regenerated files — never edit `swift/**/Generated/` by hand.

Changing the mutating core (slim engine, `live.go`, `disabled_store.go`, `profile_save.go`) or any
destructive command needs the same change kept in step in both implementations, plus a parity run; see
[docs/parity-check.md](docs/parity-check.md).

See [CLAUDE.md](CLAUDE.md) for the full architecture notes and safety invariants, and
[docs/swift-port-plan.md](docs/swift-port-plan.md) for the port's plan and status.
