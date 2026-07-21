# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

simslim runs many more iOS simulators on one Mac by disabling the background
daemons a simulator doesn't need, cutting each simulator's memory ~4x. It is a Go
CLI plus a SwiftUI macOS app that wraps it. Everything is driven through
`xcrun simctl`; the tool only ever touches the simulators you point it at, never
the host Mac. macOS-only.

## Commands

```sh
go build .                      # build the CLI
go test ./...                   # run all tests (Makefile: make test)
go test -run TestName ./...     # run a single test
make check                      # full CI gate — must pass before a PR
make format                     # gofmt + swift-format (run before committing)
make app                        # build build/SimSlim.app (Go + swiftc, macOS only)
open build/SimSlim.app
```

`make check` runs `go test`, `go vet`, `swift-format lint --strict --recursive gui`,
`zsh -n scripts/build-app.sh`, and `plutil -lint gui/Info.plist`. CI (`.github/workflows/ci.yml`)
runs exactly this on macos-26 / Xcode 26.6, then builds and verifies the app bundle.

Tests are pure unit tests (parsing, delta logic, allowlist invariants) — they do
**not** boot real simulators, so they run anywhere. Only the app build and manual
runs need Xcode + an iOS runtime.

## Architecture

Single flat Go package `main` — every `*.go` file sits at the repo root, no
subpackages. `main.go` is the CLI entry point: it dispatches `os.Args[1]` to a
`cmd*` function per subcommand and enforces macOS-only up front.

**The slimming model (the core idea).** `profiles.go` defines `Categories`, an
allowlist of launchd daemon labels grouped by user-facing feature (siri, search,
icloud, …). `slimmableSet()` is the union of every label in `Categories`.
`managedSet()` adds each category's `AlwaysEnabled` compatibility services,
which simslim may only repair back to enabled; these are **the only labels the
tool may ever disable or enable.** Anything outside those sets is never touched.
`service_descriptions.go` supplies the short per-daemon explanations shown by
the GUI; its coverage and length are enforced in `profiles_test.go`.
`slim.go`'s `ensure()` boots the device, reads its currently
disabled labels, computes a `delta` against the desired set, and applies the
changes with `launchctl disable/enable` run inside the simulator via
`simctl spawn`. The disables are written as persistent launchd overrides, so a
slimmed simulator comes up slim on every subsequent boot in one boot. `on`
disables the profile; `off` re-enables the whole managed set back to stock.

**simctl wrapper.** `simctl.go` is the only place that shells out to
`xcrun simctl` (list/boot/shutdown/clone/erase/delete/spawn). `measure.go` sums
`phys_footprint` across the simulator's launchd process tree (via `pgrep`/`ps`/`top`)
— that's the memory figure that decides how many simulators fit. `disk.go`,
`disk_cleanup.go`, and `disk_inventory.go` handle disk measurement and the
separate, permanent disk-cleanup feature.

**JSON is a contract.** Every read-only and management command supports `--json`.
The structs in `output.go` (`DeviceSummary`, `StatusOutput`,
`SimulatorMutationOutput`, etc.) plus the category/plan structs are the stable
interface the SwiftUI app decodes. Changing a JSON field breaks the GUI in
`gui/*.swift` — keep them in sync. `gui/Backend.swift` invokes the bundled CLI
with `--json` and decodes these types; there is no other IPC.

**The SwiftUI app** (`gui/`) has no Xcode project. `scripts/build-app.sh` compiles
the Swift sources directly with `swiftc`, cross-builds the Go CLI, bundles it into
`SimSlim.app/Contents/Resources/simslim`, generates the icon, and ad-hoc codesigns.
The app is a thin front end that shells out to that bundled binary.

## Safety invariants — preserve these

- **Never add a deadlock-prone daemon to `Categories`.** A handful of daemons wedge
  a simulator when disabled. `profiles_test.go` holds a `forbiddenLabels` list and
  asserts none appear in any category; if you add labels, keep that test green.
- **Only managed labels are ever mutated.** `delta()` is scoped to `managedSet()`
  on both sides. Compatibility labels are omitted from every desired slim state,
  so they can only be repaired to enabled.
- **Destructive/management commands resolve the exact UDID first** (`findDevice` /
  `shutdownIfBooted`) so a `simctl` alias like `all` can never fan out a boot,
  erase, delete, or filesystem path across every simulator.
- **Disk cleanup only removes allowlisted per-device directories**, refuses to run
  without `--confirm`, and never touches the shared, signed iOS runtime (built-in
  apps, core OS language resources). `disk-plan` is strictly read-only. Durable
  storage (Documents, app bundles, user media) is measured but never deletable.

## Conventions

- Flags may appear before or after positional args (e.g. `simslim on <udid> --except search`);
  `parseInterspersedFlags` in `main.go` handles this, since stdlib `flag` stops at
  the first positional. Use it for any command that takes both flags and a UDID.
- Two timeouts live in `main.go`: `shutdownTimeout` (30s) and `bootTimeout` (6min,
  because a first slim reconfigure boots twice).
- Progress for multi-minute operations goes to **stderr** via the `reporter` type;
  machine-readable JSON goes to **stdout**. Under `--json`, suppress the stderr
  chatter so consumers reading a combined stream still get clean JSON.
- Memory estimates (`ApproxMemoryMB`) are iOS-26.5 clean-boot medians and are
  **not additive**. Every category must have a positive measured estimate.

## Git

Never add a `Co-Authored-By: Claude` trailer or any "Generated with Claude" footer
to commit messages.
