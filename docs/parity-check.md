# Go-vs-Swift parity check

`scripts/parity.sh` runs the same commands through the Go CLI and the Swift CLI and diffs the normalized
stdout, stderr and exit code. It is the plan's M7 step, run by hand on a Mac with Xcode, a simulator
runtime, python3 and Go. Docker or Linux cannot run it: simslim needs macOS, `xcrun simctl` and real
simulators.

```sh
git pull
scripts/parity.sh                      # read-only: no simulator is changed
scripts/parity.sh --mutating           # + on/off/enable/disable/clone/... on a scratch simulator
scripts/parity.sh --mutating --watch   # + watch --json events (slow, and slims every shut-down simulator)
```

Results go to `build/parity/<timestamp>/`: `report.txt` holds every diff, and `go/` and `swift/` hold the
raw and normalized output of each command. Exit status is 1 if anything differs.

## Prerequisite check: Go toolchain

Determine availability without installing anything:

```sh
command -v go >/dev/null 2>&1 && echo "go: available" || echo "go: unavailable"
```

Never install Go (via Homebrew, `asdf`, or otherwise) to satisfy this check — its absence is a valid
environment, not a failure to fix.

### Go available

Run the full gate:

```sh
make check          # go test, go vet
make app-check      # gui swift-format lint, build-app.sh syntax, Info.plist lint
make swift-test      # swift test
make swift-gen-check # Generated/ catalog still matches profiles.go/features.go/service_descriptions.go
make verify-deps     # Swift port: system modules only, no network, no third-party libs
scripts/parity.sh    # Go-vs-Swift parity, read-only; add --mutating for a scratch-simulator run
```

### Go unavailable

Skip every Go-dependent step — `make check`, `make test`, and `scripts/parity.sh` all require the `go`
binary (`make app` does not: it bundles the Swift CLI) and will fail outright (`parity.sh` exits 2 with "go not found (or set GO_BIN)"). Run only what
doesn't need it:

```sh
make swift-test      # swift test
xcrun swift-format lint --strict --recursive swift/Sources swift/Tests
make swift-gen-check  # parses profiles.go etc. as text with python3 — no go toolchain needed
make verify-deps      # ./scripts/verify-deps.sh
zsh -n scripts/build-app.sh
plutil -lint gui/Info.plist
```

## What it covers

- **Static:** `help`, `version`, `profiles` (every category), `doctor --list`, `disk-categories`, `list`,
  `top --json`, and usage errors, including `on all`, `erase all` and `delete all`, which must never reach
  simctl.
- **Per simulator (read-only):** `status`, `verify`, `doctor`, `measure`, `size`, `disk-plan`.
- **`--mutating`:** creates `simslim-parity-<pid>`, then for each CLI in turn resets it and runs `on`, `off`,
  `on --except`, `on --keep`, `on --profile`, `on --no-reboot`, `enable`, `disable`, `doctor`, `shutdown`,
  `rename`, `clone`, `repair-clone`, `erase`. `on` and `off` are compared as text (they take no `--json`).
  After the slimming steps, after `shutdown`, and after `clone`/`erase` it also saves the contents of the
  host-side `disabled.plist`, so persisted overrides are compared, not only the printed text. The
  scratch simulator and its clone are deleted on exit unless you pass `--keep-device`.
- **`--watch`:** compares the sequence of `watch --json` event names for a simulator created and booted while
  `watch` runs.

## Normalization

UDIDs, the home directory, binary paths, durations and the version string are masked. With "shape" mode
(`measure`, `top`) all numbers are masked too, since live memory differs between two runs. JSON is
re-serialized with sorted keys, and `null` equals `[]`.

## Differences already known (from the code review)

Expected, and harmless to the macOS app; they appear in the report as diffs unless noted:

- `top --json` with no booted simulators: Go `"sims": null`, Swift `[]` (masked by the normalizer).
- `disk-clean`, `erase`, `delete` on a Booting or Shutting Down simulator: Swift refuses, Go proceeds.
- `clone`: Swift fails if the device list call fails, and its `lsof` containment is stricter.
- `disk-plan` fails in Swift when any path component of a target is a symlink; Go accepts a link that
  stays inside the data directory.
- Profile file parsing: Swift rejects trailing text and accepts trailing commas and a BOM; duplicate keys
  keep the first value in Swift and the last in Go.
- Non-JSON error text for file and I/O errors differs (Foundation vs Go wording).
- `simslim --json list` is accepted by Swift only; `watch extra-arg` is an error in Swift only.
- Ctrl-C during `on`, `off` and `clone` does not run Go's cleanup in Swift.
- `mutating/*.store` can transiently see a truncated, missing, or parseable-but-incomplete host-side
  `disabled.plist`, because CoreSimulator's `launchd_sim` rewrites it asynchronously (see "Open question"
  below). `snapstore()` trusts a read only after two identical ones in a row (up to ~4.5s), treats a file
  absent for ~1.5s as really absent, and otherwise writes "store did not settle" to the step's stderr so the
  comparison fails visibly.

Anything else in `report.txt` is a real difference to investigate. When one is intentional, add it to this
list; when it is a bug, fix the Swift side and re-run.

## Open question: `disabled.plist` lags live changes

Observed on the maintainer's Mac; not yet explained. The host-side
`/private/var/tmp/com.apple.CoreSimulator.SimDevice.<udid>/disabled.plist` is CoreSimulator's own
undocumented bookkeeping. Both CLIs check the authoritative in-guest `launchctl print-disabled` state before
reporting success, and that matched between Go and Swift in every trial.

1. Right after `on` returns, the file can be mid-rewrite (truncated at a block boundary, or parseable but
   missing entries) and settles within seconds. This showed up more often with the Swift CLI than with Go,
   possibly only because Go's commands take slightly longer to return. Both tools write their own part of
   the file atomically (temp file and `rename(2)`).
2. After a live `enable`, `disable` or `on --no-reboot`, which never write the store directly, the file was
   seen to stay stale for the Swift CLI well past any reasonable retry window, while an in-guest check showed
   both tools had disabled the same labels. This is why the script snapshots the store after `shutdown`
   instead of right after `on --no-reboot`. If the file still differs there, the Swift live path does not
   persist what Go's does, which is worth investigating.

Also open: whether anything else that reads this file right after a live call (the macOS app, `watch`'s
pre-boot seeding) must tolerate the same staleness.
