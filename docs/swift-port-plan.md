# simslim Swift port: plan

Status: draft for review. Nothing in this plan is implemented yet.
Branch: `swift-port` (no upstream). Go code stays untouched as the reference until the port reaches parity.

## 1. Goal and non-goals

**Goal.** A `simslim` CLI built only with the Xcode toolchain already on the Mac, with no Go toolchain and no third-party code, whose dependencies can be verified by a short script anyone can run. It keeps the existing `--json` contract, so `gui/*.swift` keeps working unchanged.

**Non-goals.**
- Changing behavior or adding features during the port.
- Linux or CI portability (the tool is macOS-only already).
- Replacing the SwiftUI app. Only its bundled CLI changes.

## 2. Size of the job (from the Go source)

| Area | Go files | Lines |
|---|---|---|
| CLI commands and dispatch | `cmd/simslim/main.go`, `app.go` | ~1350 |
| Live TUI (`top`) | `cmd/simslim/top.go` | ~650 |
| Profile wizard | `cmd/simslim/wizard.go` | ~360 |
| Clone / repair-clone | `clone.go` | ~880 |
| simctl wrapper | `simctl.go` | ~675 |
| Disk cleanup / inventory | `disk_cleanup.go`, `disk_inventory.go`, `disk.go` | ~740 |
| Allowlist, categories, descriptions | `profiles.go`, `service_descriptions.go`, `features.go` | ~810 |
| Slim engine | `slim.go`, `disabled_store.go`, `launchd_batch.go`, `verify.go` | ~710 |
| watch | `watch.go`, `watch_dirs_darwin.go` | ~520 |
| live enable/disable, profiles on disk | `live.go`, `profile_file.go`, `profile_save.go` | ~640 |
| measure / fleet / output | `measure.go`, `fleet.go`, `output.go` | ~420 |
| **Total non-test** | | **~12.7k** |
| Tests | 40 `_test.go` files | ~4.9k |

Expect roughly 9 to 12k lines of Swift. This is an estimate, not a measurement.

## 3. Dependency policy: controlled and independently verifiable

### 3.1 The rule

The only code the Swift tool may use is:

1. The Swift standard library.
2. Apple system modules: `Foundation`, `Darwin`, `Dispatch` (CLI); additionally `AppKit` and `SwiftUI` (the existing GUI).
3. Test-only, toolchain-bundled: `XCTest` or `Testing`, plus `swift-format` from Xcode for lint.

No Swift packages, no vendored source, no downloaded binaries, no plugins, no build scripts that fetch anything. Every item in this list ships inside Xcode, so approving Xcode approves it.

### 3.2 Layout choices that keep this checkable

- **SwiftPM with an empty dependency list.** `swift/Package.swift` declares `dependencies: []`. This gives `swift build` and `swift test` without any third-party code. The GUI keeps its current bare-`swiftc` build in `scripts/build-app.sh`.
- **Three targets:** `SimSlimKit` (library, all logic), `simslim` (executable, argument parsing and printing only), `SimSlimKitTests`. This mirrors the Go split where the library never writes to stdout.
- **One place for subprocesses.** All `Process` use lives in `Subprocess.swift`. Each executable is an absolute path from a closed enum: `/usr/bin/xcrun`, `/usr/bin/plutil`, `/usr/bin/du`, `/usr/bin/pgrep`, `/bin/ps`, `/usr/bin/top`, `/usr/sbin/lsof`, `/bin/stty`. No `PATH` lookup. This is stricter than the Go version, which resolves most of them through `PATH`.
- **One place for the filesystem roots it may mutate**, with the same guards as `requireDescendant` / `requireResolvedDescendant`.

### 3.3 Verification gate: `scripts/verify-deps.sh`

A single script, run by `make check` and runnable by the security team on a clean checkout. It must pass or the build fails.

| # | Check | How |
|---|---|---|
| 1 | No packages | `swift/Package.swift` has `dependencies: []`; `Package.resolved` absent; no `Packages/`, `vendor/`, `.build/checkouts` |
| 2 | Imports are allowlisted | grep every `import` in `swift/` and `gui/`; any module outside the allowlist fails |
| 3 | No network APIs | grep for `URLSession`, `URLRequest`, `URL(string:` with a scheme, `NWConnection`, `CFNetwork`, `Network` import, sockets |
| 4 | Subprocess closure | every `Process()` is in `Subprocess.swift`; every executable path is in the enum |
| 5 | Linked libraries | `otool -L` on the release binary; every entry must be under `/usr/lib` or `/System/Library`; compared to a committed `expected-libs.txt` |
| 6 | Symbols | `nm` / `strings` on the release binary must show no network symbols |
| 7 | No fetching in the build | grep `Package.swift`, `Makefile`, and scripts for `curl`, `wget`, `git clone`, `http(s)://` |
| 8 | Test hooks absent from release | the release binary does not contain the test-override env var names (see 4.2) |
| 9 | Runtime network check (optional) | run `list`, `status`, `--json` commands under `sandbox-exec` with `(deny network*)` and confirm they still work |

`docs/DEPENDENCIES.md` records the result in plain words: the allowlist, the expected `otool -L` output, and "third-party packages: none". It is generated, so it cannot drift from the code.

### 3.4 Reproducibility and provenance

- Build with `-file-prefix-map` so paths do not leak into the binary. Build twice and compare hashes. Treat byte-identical output as a goal and report if it isn't achieved (Swift determinism is not guaranteed).
- `scripts/sbom.sh` prints the toolchain version, the allowlisted modules, and the linked system libraries. It will say "third-party: none".
- Ad-hoc codesign as today. Notarization is a separate decision and needs an Apple developer identity.

## 4. Test strategy

### 4.1 Layer 1: pure unit tests (run anywhere, in `make check`)

Port the Go tests that encode safety or contract:
- `profiles_test`: allowlist invariants, `forbiddenLabels`, every category has a positive memory estimate, descriptions cover every label.
- `features_test`, `profile_file_test`, `profile_save_test`.
- Delta logic scoped to the managed set (the "only managed labels are ever mutated" invariant).
- Parsing: `simctl list -j`, `print-disabled`, `launchctl list`, `disabled.plist`.
- Disk-cleanup path guards, including the symlink cases.
- `--confirm` refusal.

### 4.2 Layer 2: component tests with a fake `xcrun`

Mirrors `simctl_test.go`. `SimctlRunning` is a protocol, and unit tests inject a fake. For black-box CLI tests there is a debug-only override of the executable paths, compiled under `#if DEBUG`. The release binary must not contain it (gate check 8).

### 4.3 Layer 3: contract tests against the GUI

`gui/Models.swift` already decodes the CLI's JSON. A test compiles `Models.swift` into the test target and decodes the Swift CLI's `--json` output for every command. If a field is renamed or dropped, the build breaks, instead of the GUI breaking at runtime. A second check compares the key sets of each JSON output with the Go tool's, using fixtures recorded once from the Go binary on a machine that has Go.

### 4.4 Layer 4: integration tests on real simulators (opt-in)

Enabled only with `SIMSLIM_INTEGRATION=1`; never part of `make check`.

Safety rules:
- Run in an **isolated device set** (`--set <temp dir>`), never the default set.
- Create a dedicated throwaway device with `simctl create`, record its UDID, and **refuse to touch any UDID that is not in that record**.
- Always clean up in teardown, including on failure. Delete only the recorded UDID.
- Abort before doing anything if the device cannot be created.

Scenarios: list and status on a clean device; `on` then `verify`; reboot and confirm persistence; `off`; `on --no-reboot`; live `enable` and `disable` with `--save`; offline fast path; `doctor`; `measure`; `clone` and `repair-clone`; `disk-plan` (read-only) and `disk-clean --confirm` on the throwaway device only; `watch` seeing a new device.

### 4.5 Side-by-side parity (needs Go, so the personal Mac)

For the same throwaway device, run the Go and Swift tools and compare: `--json` output (modulo timing fields), and the resulting disabled-label set. Xcode 27.2 is newer than the Xcode 26.6 the upstream CI pins, so any difference is first checked against plain `simctl` before blaming the port.

## 5. Milestones

Each milestone ends with: gate script green, unit tests green, and a short written note of what was verified and what was not.

- **M0 Scaffold.** `swift/` package, empty dependencies, `verify-deps.sh`, `DEPENDENCIES.md` generation, CI wiring, fake-xcrun harness.
- **M1 Core model.** Allowlist (`profiles.go`, `service_descriptions.go`, `features.go`) as data, delta logic, profile files. All invariant tests ported first.
- **M2 simctl and read-only commands.** `Subprocess`, `simctl` wrapper, `list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `size`, `disk-categories`, `disk-plan`, with JSON contract tests.
- **M3 Slimming.** `on`, `off`, `on --no-reboot`, the `launchctl` pool (8 workers), `disabled.plist` offline fast path, `unloadInBatch`, launchd retry delays.
- **M4 Live and management.** `enable`, `disable`, `--save`, `boot`, `shutdown`, `rename`, `erase`, `delete`, `clone`, `repair-clone`, `disk-clean`. The destructive ones get the most review.
- **M5 watch.** kqueue directory watch, pre-slim of new devices, `watch --json` events.
- **M6 Interactive.** `top` live view (plain ANSI redraw, no TUI library) and the `profile` wizard (`stty` raw mode).
- **M7 Integration and parity.** Layer 4 and 4.5 runs, fix differences.
- **M8 Cutover.** `build-app.sh` bundles the Swift CLI, Go removed from the app build, README and `CLAUDE.md` updated. The Go tree stays until you decide to remove it.

## 6. Risks

- **Undocumented behavior.** `disabled.plist` location and format is a CoreSimulator internal. The Go tool already treats it as best effort and falls back to `launchctl`; the port keeps that fallback.
- **Xcode 27 differences.** `simctl` output or runtime layout may differ from what upstream tested. Surfaces in M2 and M7.
- **Concurrency.** Go's goroutines and contexts map to Swift concurrency. The pool, timeouts (`BootTimeout`, `SpawnTimeout`, `ShutdownTimeout`) and cancellation (`slimPass`) need careful porting, with tests.
- **`top` and wizard.** Reimplementing terminal UI without a library is the most visible behavior change. Scope can be cut here if needed.
- **Fork drift.** After the port, upstream Go fixes do not flow in automatically.
- **Licensing.** The port is a derivative of MIT code; keep `LICENSE` and the copyright notice.
- **Security-team acceptance.** Self-built code from this repo is a policy question for your team, not something this plan assumes.

## 7. Decisions (resolved)

1. **Scope: reduced first.** The priority is the RAM effect when running many simulators. The first release covers the CLI commands that produce it: `list`, `profiles`, `status`, `verify`, `doctor`, `measure`, `on` (including `--no-reboot` and `--profile`), `off`, `enable`/`disable` (with `--save`), `boot`, `shutdown`, and `watch`. See section 8 for what is deferred.
2. **Location:** `swift/` inside this repo.
3. **Go tree:** kept until cutover only, as the parity reference. At cutover, tag the last Go commit and remove the tree. Upstream stays reachable through a git remote. Reason: `go.mod` and `go.sum` would otherwise keep the 19 third-party modules in the tree and weaken the "no third-party code" claim.
4. **Dependency gate:** run by hand with `make verify-deps`. No CI wiring for now; revisit later.
5. **Independent review: yes**, scoped to the mutating core (slim engine, `live.go`, `disabled_store.go`, `profile_save.go`) and, later, to any deferred destructive code before it is ported.

## 8. Deferred (follow-up tasks)

These are not in the first release. The SwiftUI app depends on several of them, so the app keeps bundling the Go CLI until they are ported. No cutover of the app happens before then.

| Item | Why deferred | Notes |
|---|---|---|
| `top` live view | Not needed for the RAM effect; the one-shot `measure` covers the numbers | Terminal redraw without a TUI library. Keep `--json` one-shot. |
| `profile` wizard | Profiles can be written by hand or via `enable --save` | Needs `stty` raw mode. |
| `clone`, `repair-clone` | File writes in device data | Needs destructive-code review first. |
| `rename`, `erase`, `delete` | Modify or remove whole simulators | Used by the GUI. Needs review first. |
| `size`, `disk-categories`, `disk-plan`, `disk-clean` | `disk-clean` calls `RemoveAll` | Read-only parts may come first. `disk-clean` needs review first. |
| App cutover to the Swift CLI | Requires all of the above | Then remove the Go tree. |

## 9. Revised milestones for the first release

- **M0** Scaffold: package, subprocess layer, dependency gate, `make verify-deps`.
- **M1** Core model: allowlist, categories, features, delta logic, profile files, with the invariant tests ported first.
- **M2** simctl and read-only commands: `list`, `profiles`, `status`, `verify`, `doctor`, `measure`. **Done** (167 tests; every command checked through a fake host; the app's real `gui/Models.swift` decodes the JSON; `measure` cross-checked against `pgrep`/`ps`/`top` on a real Mac). Also run against a live throwaway simulator in an isolated device set (Xcode 27.2, iOS 27.2).
- **M3a** Slimming: `on`, `off`, `on --no-reboot`, `boot`, `shutdown`, offline fast path, batch unload, 8-worker pool. **Done** (222 tests; 12 mutations in the slimming core, all caught; live run on a throwaway simulator: 246 to 83 processes, about 10.5 GB to 2.7 GB, slim persists across shutdown and boot, `off` restores stock). Awaiting the independent review of this core.
- **M3b** Live `enable`/`disable` and `--save` (`live.go`, `profile_save.go`): **Done** (14 mutations in the new code caught after two added tests; run live on a throwaway simulator). Independently reviewed: one real bug (`--save` replaced a symlinked profile named by a bare file name) and several test gaps, all fixed.
- **M5a** `rename`, `erase`, `delete`: **Done** (reviewed independently; no route for an alias or flag to reach the destructive simctl calls; live run on a throwaway simulator). One deliberate divergence from Go: erase and delete refuse a simulator that is Booting or Shutting Down, where Go runs them. Names print with Go's `%q` rules and trim with Go's space set. Remaining for the app cutover: `size`, `disk-categories`, `disk-plan`, `disk-clean`, `clone`.
- **M4** `watch`: **Done** (kqueue device-set watcher, pre-boot store seeding, per-device after-boot slim with cancellation, `--json` events; 40 tests, 19 mutations caught or hung). Not run live: `watch` always scans the user's default device set, so a live run would slim their real simulators; run it on a Mac where that is intended. Cancellation stops the next command, not one already running (Go kills it).
- **M5** Integration tests on a throwaway simulator, independent review of the mutating core, and parity run against the Go tool.
