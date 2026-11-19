# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

simslim runs many more iOS, tvOS, watchOS, and visionOS simulators on one Mac by disabling the background
daemons a simulator doesn't need, cutting each simulator's memory ~4x. It is a dependency-free Swift CLI,
built with the Xcode toolchain alone, plus a SwiftUI macOS app that wraps it. Everything is driven through
`xcrun simctl`; the tool only ever touches the simulators you point it at, never the host Mac. macOS-only.

This repository was originally an independent Swift port of [MobAI's simslim](https://github.com/mobai-app/simslim)
(Go); the port reached parity and the Go tree was removed. See
[docs/remove-go.md](docs/remove-go.md) for how, and
[docs/parity-check.md](docs/parity-check.md) for how the ported behavior was checked against the Go
reference, tagged `go-reference-final`.

## Commands

```sh
make swift-lint       # swift-format --strict over swift/Sources and swift/Tests
make swift-test       # cd swift && swift test
make verify-deps      # system modules only, no network symbols, no third-party libs
make app-check        # gui swift-format lint, build-app.sh syntax, Info.plist lint
make app              # build build/SimSlim.app (swiftc + swift build, macOS only; no Go)
open build/SimSlim.app
make format           # swift-format over gui (run before committing)
```

CI (`.github/workflows/ci.yml`) runs lint, tests, the dependency audit, `app-check`, and the app build and
bundle verification, all in one job on macos-26 / Xcode 26.6.

Tests are pure unit tests (parsing, delta logic, allowlist invariants) — they do
**not** boot real simulators, so they run anywhere. Only the app build and manual
runs need Xcode + an iOS runtime.

Go-vs-Swift parity checks (`scripts/parity.sh`) still exist for regression-checking against the last Go
build (tag `go-reference-final`, built from a sibling worktree) and need a Go toolchain only to run that
script; see [docs/parity-check.md](docs/parity-check.md#prerequisite-check-go-toolchain) for which checks to
run when Go is and isn't available — never install Go just to make that check pass.

## Architecture

Two targets under `swift/`: `SimSlimKit` is the importable library holding every piece of slimming logic
and **no external dependencies**; `SimSlimCLI` is the command layer, invoked by the tiny
`swift/Sources/simslim/main.swift` executable. `CLI.run(_:)` (`SimSlimCLI/CLI.swift`) dispatches each
subcommand to a `cmd*` function (`SimSlimCLI/Commands.swift` and friends) and enforces macOS-only up front.

Anything that talks to a terminal — printing, `--json` encoding, the interactive wizard
(`WizardModel.swift`/`WizardTerminal.swift`), `top`'s live screen (`TopCommand.swift`/`TopModel.swift`/
`TopTerminal.swift`) — lives in `SimSlimCLI`. The library never writes to stdout; it returns values and
reports progress through the `Reporter` callback the caller supplies.

Public identifiers in `SimSlimKit` are its API, so renaming one is a breaking change for importers as well
as for the CLI.

**The slimming model (the core idea).** `Catalog.swift` defines `Catalog.categories`, an allowlist of
launchd daemon labels grouped by user-facing feature (siri, search, icloud, …), plus the
`Generated/CatalogData.swift` seed data (hand-maintained now; the folder name is historical). Categories may overlap — a label lives in every category whose
feature needs it (e.g. the AMS payment-sheet daemons are in both `store` and `icloud`), and
`Profile.desired()` keeps a label enabled when **any** excepted category lists it. `Catalog.slimmableSet` is
the deduplicated union of every label in `Catalog.categories`.
`Catalog.managedSet` adds each category's `alwaysEnabled` compatibility services,
which simslim may only repair back to enabled; these are **the only labels the
tool may ever disable or enable.** Anything outside those sets is never touched.
`ProfileFile.swift` loads a committed JSON profile (`simslim on --profile <path>`)
whose `except`/`keep` arrays mirror the flags of the same name, validates it
against the allowlist, and resolves it to a `Profile`. The `profile` command's interactive wizard lives in
`WizardModel.swift`/`WizardTerminal.swift`.
`Features.swift` defines `Catalog.features` (data in `featureList`), a finer-grained catalog than `Catalog.categories`:
each feature (push, storekit, universal-links, …) names just the daemons one
testable capability needs. `doctor` reads a booted simulator's disabled labels
and reports any required feature whose daemons are down, exiting non-zero — a CI
preflight. `FeaturesTests.swift` asserts every feature label is managed, including
required services that earlier versions could have disabled.
`Slim.swift`'s `ensure()` rejects a non-empty slim profile on runtimes older than
iOS/tvOS 18.5, watchOS 11.5, or visionOS 2.5 before booting or mutating the device, then reads the currently disabled
labels, computes a `delta` against the desired set, and applies the changes with
`launchctl disable/enable` run inside the simulator via `simctl spawn`, a pool of
`spawnWorkers` (8) at a time. It reboots
and reads the state back before reporting persistence. `on` disables the profile;
`off` remains available on every runtime and re-enables the whole managed set.
`Profile.desired(for:)` keeps `com.apple.homed` enabled on watchOS, which
re-enables that service after startup, and `com.apple.mobileassetd` on visionOS,
whose simulated surroundings are mobile assets. Slimming, verification, and per-device
status totals use this platform-specific profile; `Profile.desired()` remains the
platform-independent catalog for profile editors. `Device.platform` identifies
iOS, tvOS, watchOS, or visionOS (CoreSimulator's `xrOS` runtimes); an empty platform defaults to iOS for library callers.
`enableSlimNoReboot` (`on --no-reboot`) skips the reboot: it runs `launchctl
disable` + `launchctl bootout` per label so the daemon stops in the current boot
session, which is the only slimming possible on runtimes older than iOS 18.5.
Before that per-label pass, `unloadInBatch` stops most labels at once: it finds
each label's job plist under the runtime's RuntimeRoot (`Device.runtimeID` →
`runtimeRoot`, used only when the plist's own `Label` matches) and passes them to
one `launchctl unload -w` per 64 plists, which writes the same override as
`disable` and removes the job like `bootout`. It then reads `print-disabled` and
`launchctl list` back, and only labels still enabled or loaded take the
per-label path; any failure in the batch just means more labels do.

**The offline fast path.** On a runtime with persistent overrides `ensureOffline`
takes over: `DisabledStore.swift` writes the overrides directly and boots the
device once, already slim, skipping every `launchctl` spawn *and* the reboot that
would apply them (measured 2m14s → 33s for 170 labels). A **booted** device gets
there too — an override only takes effect at the next boot, so `ensure` reads its
live state, returns early when the profile already matches, and otherwise spends
the shutdown the device already owed before handing off. There is no shell inside
any iOS runtime (`RuntimeRoot/bin` holds only `df` and `launchctl`), so batching
transitions through a spawned `/bin/sh` is not an option; the offline path uses
the pool. `launchd_sim` is a *host* process, so that store is not in the
device's data directory — it sits beside the device's `launchd.log` in
`/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist`, keyed
only by UDID. It is an undocumented CoreSimulator detail, so treat it as
best-effort: writes **merge** (the runtime keeps its own explicit-enable entries
there, and unmanaged labels are never simslim's business), the booted device is
always read back with `print-disabled` rather than trusted, and anything that
does not work out throws so `ensure` falls back to the
`launchctl` path. A store problem must never surface as a command failure.
`Watch.swift` uses the same store to slim a shut-down device before it boots
(`preslimDevice`): it only adds the profile's disables, to every shut-down
device on startup. A kqueue `NOTE_WRITE` watch on each device-set directory
(`DirWatcher.swift`, re-attached each scan interval while a set directory is
missing) seeds a new device from its `device.plist` within milliseconds of `simctl create`,
without waiting for `simctl list`. A boot that starts first is logged and
caught by the no-reboot slim at boot, which stays as the read-back and fallback.
Each boot's after-boot pass has its own cancel (`Watcher.Pass.cancel()`), called when the
device shuts down or is deleted, so a pass never retries into the next boot; a
superseded pass reports `stopped`, never `slimmed`. `Watcher.run` emits
`WatchEvent`s, which `watch --json` prints one per line as a stable contract.

**Live enable/disable.** `Live.swift` holds `enableServices`/`disableServices`
(`simslim enable`/`disable`), which act on a booted simulator only and keep no
state, like `on --no-reboot`: the profile stays the only description of a slim
simulator. `startServices` runs one `launchctl load -w` per chunk, then per-label `enable`
and `bootstrapJobs` for what is left;
`stopServices` is the unload/disable/bootout path `on --no-reboot` uses.
Everything is read back; a label that loads only at the next boot is reported in
`notStarted`, not as an error. `disable` keeps a label a named category shares
with another category whose labels are all enabled right now
(`enabledNeighbours`), and reports it in `stillEnabled`; a label named on its
own is always stopped. A simulator that is not booted is an error unless
`--save` is given. `ProfileSave.swift`'s `saveServices` (`--save <file>`) adds or
removes categories in a profile file's `except` and labels in its `keep`,
keeping order and other fields, skipping duplicates, starting a missing file
from the default (empty) profile, and writing atomically; the file is validated
first and written only after the live change succeeded. Launchd reads
(`readLaunchd`) retry launchd_sim's error 124 ("Domain is tearing down",
answered for a few seconds around a boot or reboot) and an attempt that ran out
of `spawnTimeout`, on `retryDelays`, and nothing else; later
slimming passes pause on the same delays. Reads and per-label
transitions go through `Subprocess`, whose `waitDelay` abandons the output
pipe a killed `xcrun`'s simctl child would otherwise hold open forever.

**simctl wrapper.** `Simctl.swift` is the only place that shells out to
`xcrun simctl` (list/boot/shutdown/clone/erase/delete/spawn). `Measure.swift` sums
`phys_footprint` across the simulator's launchd process tree (via `pgrep`/`ps`/`top`)
— that's the memory figure that decides how many simulators fit. `measureMany`
keeps the per-process detail (footprint + cpu, from the same snapshot) for the
`top` drill-down. `Fleet.swift`'s `fleetSnapshot` composes booted devices + slim
status + measurements into the fleet view; the live TUI is `SimSlimCLI/TopCommand.swift`
plus `TopModel.swift`/`TopTerminal.swift` (plain ANSI redraw, no library), which also has a
`--json`/non-TTY one-shot fallback. `DiskCleanup.swift` and its supporting files handle disk measurement
and the separate, permanent disk-cleanup feature.

**JSON is a contract.** Every read-only and management command supports `--json`.
The structs in `Output.swift` (`DeviceSummary`, `StatusOutput`,
`SimulatorMutationOutput`, `ServicesOutput`, etc.) plus the category/plan
structs are the stable interface the SwiftUI app decodes. Changing a JSON
field breaks the GUI in `gui/*.swift` — keep them in sync. `gui/Backend.swift`
invokes the bundled CLI with `--json` and decodes these types; there is no
other IPC.

**The SwiftUI app** (`gui/`) has no Xcode project. `scripts/build-app.sh` compiles
the Swift sources directly with `swiftc`, builds the CLI with `swift build` (stamping the version into
`swift/Sources/SimSlimKit/Version.swift` for the build, then restoring the file), bundles it into
`SimSlim.app/Contents/Resources/simslim`, generates the icon, and ad-hoc codesigns.
The app is a thin front end that shells out to that bundled binary.

## Safety invariants — preserve these

- **Never add a deadlock-prone daemon to `Catalog.categories`.** A handful of daemons wedge
  a simulator when disabled. `ProfilesTests.swift` holds a `forbiddenLabels` list
  (`swift/Tests/SimSlimKitTests/Generated/ForbiddenLabels.swift`) and
  asserts none appear in any category; if you add labels, keep that test green.
- **Only managed labels are ever mutated.** `delta()` is scoped to `Catalog.managedSet`
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

- The CLI has no third-party dependencies; its own flag parser lives in `SimSlimCLI/Arguments.swift`, with
  each command's flags declared in `CLI.commandSpecs` (`CLI.swift`). Flags may appear before or after
  positional args (e.g. `simslim on <udid> --except search`). `--set`, `--boot-timeout`, and
  `--spawn-timeout` are global flags (`CLI.globalSpecs`). `CLI.run(_:)` owns `version`/`help`/no-args and
  the macOS-only guard before dispatching to a `cmd*` function, and routes every command error through a
  shared `simslim: <msg>` formatter (exit 1); unknown commands exit 2 with usage.
- Two timeouts: `Simctl.shutdownTimeout` (30s, `Lifecycle.swift`) and the boot timeout (10min default,
  because a first slim reconfigure boots twice), resolved in `SimSlimCLI/CLI.swift` from the global
  `--boot-timeout` flag (env `SIMSLIM_BOOT_TIMEOUT`) and passed down as a parameter, so slow CI runners can
  raise it where the per-daemon `launchctl` transitions would otherwise blow the deadline mid-reconfigure.
- Progress for multi-minute operations goes to **stderr** via the `Reporter` callback;
  machine-readable JSON goes to **stdout**. Under `--json`, suppress the stderr
  chatter so consumers reading a combined stream still get clean JSON.
- Every Swift file starts with `// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.`
  (`Package.swift`: the line after `swift-tools-version`). The files under `Generated/` carry
  `// swift-format-ignore-file` on line 1 and the copyright on line 2.
- `Generated/` is edited by hand now (the generator went with the Go tree). `ProfilesTests` and
  `FeaturesTests` are its only guard: they enforce the forbidden-label list, managed/unmanaged invariants,
  and that every daemon has a short description (`testEveryServiceHasShortDescription`,
  `serviceDescriptionByLabel`). Keep them green when editing the catalog.
- Memory estimates (`approxMemoryMB`) are iOS-26.5 clean-boot medians and are
  **not additive**. Every category must have a positive measured estimate.

## Git

Never add a `Co-Authored-By: Claude` trailer or any "Generated with Claude" footer
to commit messages.
