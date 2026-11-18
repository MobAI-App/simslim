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

## What it covers

- **Static:** `help`, `version`, `profiles` (every category), `doctor --list`, `disk-categories`, `list`,
  `top --json`, and usage errors, including `on all`, `erase all` and `delete all`, which must never reach
  simctl.
- **Per simulator (read-only):** `status`, `verify`, `doctor`, `measure`, `size`, `disk-plan`.
- **`--mutating`:** creates `simslim-parity-<pid>`, then for each CLI in turn resets it and runs `on`, `off`,
  `on --except`, `on --keep`, `on --profile`, `on --no-reboot`, `enable`, `disable`, `doctor`, `shutdown`,
  `rename`, `clone`, `repair-clone`, `erase`. After each step it saves `status`, `verify` and the contents of
  the host-side `disabled.plist`, so the persisted overrides are compared, not only the printed text. The
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

Anything else in `report.txt` is a real difference to investigate. When one is intentional, add it to this
list; when it is a bug, fix the Swift side and re-run.
