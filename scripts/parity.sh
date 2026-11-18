#!/bin/bash
# Go-vs-Swift parity check for simslim. Run it on a Mac that has Xcode, a simulator
# runtime, python3 and Go. It builds both CLIs, runs the same commands through each,
# and diffs the normalized stdout, stderr and exit code. Nothing is sent anywhere.
#
#   scripts/parity.sh                 read-only commands on the existing simulators
#   scripts/parity.sh --mutating      also run on/off/enable/disable/clone/... on a
#                                     scratch simulator this script creates and deletes
#   scripts/parity.sh --watch         also compare `watch --json` events (slow, ~5 min)
#
# Options: --udid UDID (repeatable; default: up to 3 simulators plus booted ones)
#          --runtime ID --devicetype ID (scratch simulator; default: newest iOS >= 18.5)
#          --keep-device (leave the scratch simulator), --out DIR
# Env:     GO_BIN / SWIFT_BIN use prebuilt binaries instead of building.
#
# The only simulators it changes are the scratch ones it creates itself. Read-only
# runs never mutate anything. Exit status is 1 if any comparison differs.
# Known, expected differences are listed in docs/parity-check.md.

set -u
cd "$(dirname "$0")/.." || exit 2
ROOT="$PWD"

MUTATING=0
WATCH=0
KEEP=0
UDIDS=()
RUNTIME=""
DEVTYPE=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutating) MUTATING=1 ;;
    --watch) WATCH=1 ;;
    --keep-device) KEEP=1 ;;
    --udid) UDIDS+=("$2"); shift ;;
    --runtime) RUNTIME="$2"; shift ;;
    --devicetype) DEVTYPE="$2"; shift ;;
    --out) OUT="$2"; shift ;;
    -h | --help) sed -n 2,22p "$0"; exit 0 ;;
    *) echo "parity: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done

[ "$(uname)" = Darwin ] || { echo "parity: macOS only" >&2; exit 2; }
OUT="${OUT:-$ROOT/build/parity/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
NORM="$ROOT/scripts/parity-normalize.py"

# --- binaries ---------------------------------------------------------------
if [ -z "${GO_BIN:-}" ]; then
  command -v go >/dev/null || { echo "parity: go not found (or set GO_BIN)" >&2; exit 2; }
  GO_BIN="$OUT/simslim-go"
  go build -o "$GO_BIN" ./cmd/simslim || exit 2
fi
if [ -z "${SWIFT_BIN:-}" ]; then
  (cd swift && swift build -c release) >"$OUT/swift-build.log" 2>&1 || { cat "$OUT/swift-build.log"; exit 2; }
  SWIFT_BIN="$ROOT/swift/.build/release/simslim"
fi
echo "go:    $GO_BIN"
echo "swift: $SWIFT_BIN"
echo "out:   $OUT"

TOTAL=0
DIFFS=0
REPORT="$OUT/report.txt"
: >"$REPORT"
DEV=""

bin_of() { if [ "$1" = go ]; then echo "$GO_BIN"; else echo "$SWIFT_BIN"; fi; }

# normalize TOOL FILE [extra normalizer args...] -> stdout
normalize() {
  local file="$1"
  shift
  python3 -I "$NORM" --dev "$DEV" --bin "$GO_BIN" --bin "$SWIFT_BIN" "$@" <"$file"
}

# cap TOOL DIR NAME MODE args... : run one command, save normalized stdout/stderr/code.
# MODE is exact, or shape (live numbers masked).
cap() {
  local tool="$1" dir="$2" name="$3" mode="$4"
  shift 4
  mkdir -p "$dir"
  local flags=()
  [ "$mode" = shape ] && flags=(--shape)
  "$(bin_of "$tool")" "$@" >"$dir/$name.raw.out" 2>"$dir/$name.raw.err" </dev/null
  echo $? >"$dir/$name.code"
  normalize "$dir/$name.raw.out" ${flags[@]+"${flags[@]}"} >"$dir/$name.out"
  normalize "$dir/$name.raw.err" >"$dir/$name.err"
}

# compare DIRA DIRB LABEL NAME... : diff the saved artifacts of both tools.
compare_one() {
  local label="$1" name="$2" ok=1 part
  TOTAL=$((TOTAL + 1))
  for part in out err code; do
    if ! diff -u "$OUT/go/$label/$name.$part" "$OUT/swift/$label/$name.$part" >"$OUT/diff.tmp" 2>&1; then
      ok=0
      {
        echo "=== DIFF $label/$name ($part): --- go  +++ swift"
        cat "$OUT/diff.tmp"
      } >>"$REPORT"
    fi
  done
  if [ $ok = 1 ]; then echo "  ok    $label/$name"; else echo "  DIFF  $label/$name"; DIFFS=$((DIFFS + 1)); fi
}

# both LABEL NAME MODE args... : run on both tools right now and compare.
both() {
  local label="$1" name="$2" mode="$3"
  shift 3
  cap go "$OUT/go/$label" "$name" "$mode" "$@"
  cap swift "$OUT/swift/$label" "$name" "$mode" "$@"
  compare_one "$label" "$name"
}

# --- phase 1: read-only -----------------------------------------------------
echo "== read-only commands"
both static version exact version
both static help exact help
both static noargs exact
both static unknown exact bogus-command
both static profiles exact profiles
both static profiles-json exact profiles --json
for id in $("$SWIFT_BIN" profiles --json | python3 -I -c 'import json,sys;print(" ".join(c["id"] for c in json.load(sys.stdin)))'); do
  both static "profiles-$id" exact profiles "$id" --json
done
both static profiles-bad exact profiles no-such-category
both static doctor-list exact doctor --list --json
both static disk-categories exact disk-categories --json
both static disk-categories-text exact disk-categories
both static list exact list
both static list-json exact list --json
both static list-booted exact list --booted --json
both static top-json shape top --json
# argument and safety errors; none of these may touch a simulator.
both errors on-noargs exact on
both errors on-all exact on all
both errors on-booted exact on booted
both errors erase-all exact erase all
both errors delete-all exact delete all
both errors disk-clean-all exact disk-clean all --categories caches --confirm
both errors status-bogus exact status NOT-A-UDID
both errors bad-boot-timeout exact --boot-timeout abc list
both errors huge-boot-timeout exact --boot-timeout 99999999999999999999s list
both errors on-bad-category exact on 00000000-0000-0000-0000-000000000000 --except nope
both errors verify-both exact verify 00000000-0000-0000-0000-000000000000 --profile x --except y

if [ ${#UDIDS[@]} -eq 0 ]; then
  while read -r u; do UDIDS+=("$u"); done < <("$SWIFT_BIN" list --json | python3 -I -c '
import json, sys
sims = json.load(sys.stdin)
booted = [s["udid"] for s in sims if s["state"] == "Booted"]
rest = [s["udid"] for s in sims if s["state"] != "Booted"][:3]
print("\n".join(booted + rest))')
fi
for u in ${UDIDS[@]+"${UDIDS[@]}"}; do
  DEV="$u"
  l="device-${u%%-*}"
  both "$l" status exact status "$u" --json
  both "$l" status-dropped exact status "$u" --dropped --json
  both "$l" verify exact verify "$u" --json
  both "$l" verify-except exact verify "$u" --except search,store --json
  both "$l" doctor exact doctor "$u" --requires push,storekit,universal-links --json
  both "$l" measure shape measure "$u" --json
  both "$l" size exact size "$u" --json
  both "$l" disk-plan exact disk-plan "$u" --json
  both "$l" disk-plan-text exact disk-plan "$u"
done
DEV=""

# --- phase 2: mutating, on a scratch simulator --------------------------------
STORE_ROOT=/private/var/tmp
is_udid() { [[ "$1" =~ ^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$ ]]; }
EXTRA=()
cleanup() {
  local u
  if [ "$KEEP" = 0 ]; then
    for u in ${EXTRA[@]+"${EXTRA[@]}"} "$DEV"; do
      if [ -n "$u" ] && is_udid "$u"; then
        xcrun simctl shutdown "$u" >/dev/null 2>&1
        xcrun simctl delete "$u" >/dev/null 2>&1
        rm -rf "$STORE_ROOT/com.apple.CoreSimulator.SimDevice.$u"
      fi
    done
  fi
}

pick_runtime_and_type() {
  xcrun simctl list runtimes -j | python3 -I -c '
import json, sys
want = sys.argv[1:]
best = None
for r in json.load(sys.stdin)["runtimes"]:
    if not r.get("isAvailable") or r.get("platform") != "iOS":
        continue
    v = tuple(int(x) for x in r["version"].split(".")[:2])
    if v < (18, 5) or (want[0] and r["identifier"] != want[0]):
        continue
    if best is None or v > best[0]:
        best = (v, r)
if not best:
    sys.exit("no available iOS runtime >= 18.5 (use --runtime)")
r = best[1]
types = [t["identifier"] for t in r.get("supportedDeviceTypes", []) if t["name"].startswith("iPhone")]
print(r["identifier"], want[1] or types[-1])' "$RUNTIME" "$DEVTYPE"
}

snapstore() { # snapstore TOOL NAME UDID : the host-side disabled.plist, as sorted disabled labels
  local tool="$1" name="$2" u="$3" f
  f="$STORE_ROOT/com.apple.CoreSimulator.SimDevice.$u/disabled.plist"
  mkdir -p "$OUT/$tool/mutating"
  if [ -f "$f" ]; then plutil -convert json -o - "$f" 2>/dev/null; else echo '{}'; fi |
    python3 -I -c '
import json, sys
d = json.load(sys.stdin)
print(json.dumps({"disabled": sorted(k for k, v in d.items() if v is True),
                  "explicitly_enabled": sorted(k for k, v in d.items() if v is False)}, indent=1))' \
      >"$OUT/$tool/mutating/$name.store.raw.out"
  : >"$OUT/$tool/mutating/$name.store.raw.err"
  echo 0 >"$OUT/$tool/mutating/$name.store.code"
  normalize "$OUT/$tool/mutating/$name.store.raw.out" >"$OUT/$tool/mutating/$name.store.out"
  : >"$OUT/$tool/mutating/$name.store.err"
}

reset_device() {
  xcrun simctl shutdown "$DEV" >/dev/null 2>&1
  xcrun simctl erase "$DEV" >/dev/null 2>&1
  rm -rf "$STORE_ROOT/com.apple.CoreSimulator.SimDevice.$DEV"
}

mutating_steps() { # mutating_steps TOOL
  local tool="$1" d="$OUT/$1/mutating" bt="--boot-timeout 20m" clone
  reset_device
  snapstore "$tool" 00-stock "$DEV"
  cap "$tool" "$d" 01-on exact $bt on "$DEV" --json
  cap "$tool" "$d" 01-status exact status "$DEV" --json
  cap "$tool" "$d" 01-verify exact verify "$DEV" --json
  snapstore "$tool" 01-on "$DEV"
  cap "$tool" "$d" 02-off exact $bt off "$DEV" --json
  cap "$tool" "$d" 02-status exact status "$DEV" --json
  snapstore "$tool" 02-off "$DEV"
  cap "$tool" "$d" 03-on-except exact $bt on "$DEV" --except search,store --json
  cap "$tool" "$d" 03-verify exact verify "$DEV" --except search,store --json
  snapstore "$tool" 03-on-except "$DEV"
  cap "$tool" "$d" 04-on-keep exact $bt on "$DEV" --keep com.apple.apsd --json
  cap "$tool" "$d" 04-verify exact verify "$DEV" --keep com.apple.apsd --json
  snapstore "$tool" 04-on-keep "$DEV"
  printf '{ "name": "parity", "except": ["photos"], "keep": ["com.apple.apsd"] }\n' >"$OUT/profile.json"
  cap "$tool" "$d" 05-on-profile exact $bt on "$DEV" --profile "$OUT/profile.json" --json
  cap "$tool" "$d" 05-verify exact verify "$DEV" --profile "$OUT/profile.json" --json
  snapstore "$tool" 05-on-profile "$DEV"
  cap "$tool" "$d" 06-off exact $bt off "$DEV" --json
  cap "$tool" "$d" 07-on-noreboot exact $bt on "$DEV" --no-reboot --json
  cap "$tool" "$d" 07-status exact status "$DEV" --json
  snapstore "$tool" 07-on-noreboot "$DEV"
  cap "$tool" "$d" 08-enable exact enable "$DEV" icloud --json
  cap "$tool" "$d" 08-status exact status "$DEV" --dropped --json
  cap "$tool" "$d" 09-disable exact disable "$DEV" icloud --json
  cap "$tool" "$d" 09-status exact status "$DEV" --dropped --json
  cap "$tool" "$d" 10-disable-label exact disable "$DEV" com.apple.apsd --json
  cap "$tool" "$d" 10-disable-unmanaged exact disable "$DEV" com.apple.backboardd --json
  cap "$tool" "$d" 11-doctor exact doctor "$DEV" --requires push,storekit,universal-links --json
  cap "$tool" "$d" 12-measure shape measure "$DEV" --json
  cap "$tool" "$d" 13-shutdown exact shutdown "$DEV" --json
  cap "$tool" "$d" 13-disable-notbooted exact disable "$DEV" icloud --json
  cap "$tool" "$d" 14-size exact size "$DEV" --json
  cap "$tool" "$d" 14-disk-plan exact disk-plan "$DEV" --json
  cap "$tool" "$d" 15-rename exact rename "$DEV" "parity-renamed" --json
  # clone: the clone's UDID differs per run; both runs normalize it to <UDID1>.
  cap "$tool" "$d" 16-on-before-clone exact $bt on "$DEV" --json
  cap "$tool" "$d" 16-shutdown exact shutdown "$DEV" --json
  cap "$tool" "$d" 17-clone exact $bt clone "$DEV" parity-clone --json
  clone="$(python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("udid",""))' <"$d/17-clone.raw.out" 2>/dev/null)"
  if is_udid "$clone"; then
    EXTRA+=("$clone")
    snapstore "$tool" 17-clone "$clone"
    cap "$tool" "$d" 18-repair-clone exact repair-clone "$DEV" "$clone" --json
    cap "$tool" "$d" 19-delete-clone exact delete "$clone" --json
  fi
  cap "$tool" "$d" 20-erase exact erase "$DEV" --json
  snapstore "$tool" 20-erase "$DEV"
}

if [ "$MUTATING" = 1 ]; then
  echo "== mutating commands on a scratch simulator"
  read -r RUNTIME DEVTYPE < <(pick_runtime_and_type)
  [ -n "$DEVTYPE" ] || { echo "parity: no usable runtime" >&2; exit 2; }
  DEV="$(xcrun simctl create "simslim-parity-$$" "$DEVTYPE" "$RUNTIME")" || exit 2
  is_udid "$DEV" || { echo "parity: simctl create returned '$DEV'" >&2; exit 2; }
  trap cleanup EXIT
  echo "scratch simulator: $DEV ($RUNTIME)"
  mutating_steps go
  mutating_steps swift
  for f in "$OUT"/go/mutating/*.code; do
    n="$(basename "$f" .code)"
    compare_one mutating "$n"
  done
fi

# --- phase 3: watch events --------------------------------------------------
watch_run() { # watch_run TOOL : kinds of events for a simulator created and booted under watch
  local tool="$1" d="$OUT/$1/watch" log w pid i
  mkdir -p "$d"
  log="$d/events.raw.out"
  : >"$log"
  "$(bin_of "$tool")" watch --json >"$log" 2>"$d/events.raw.err" </dev/null &
  pid=$!
  sleep 10
  w="$(xcrun simctl create "simslim-parity-watch-$$" "$DEVTYPE" "$RUNTIME")"
  is_udid "$w" || { kill -INT "$pid"; echo "parity: watch simulator create failed" >&2; return 1; }
  EXTRA+=("$w")
  sleep 5
  xcrun simctl boot "$w" >/dev/null 2>&1
  for i in $(seq 1 48); do
    grep -q '"event":"slimmed"' "$log" && break
    sleep 5
  done
  xcrun simctl shutdown "$w" >/dev/null 2>&1
  sleep 10
  kill -INT "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo 0 >"$d/events.code"
  DEV="$w" normalize "$log" --kinds >"$d/events.out"
  : >"$d/events.err"
  xcrun simctl delete "$w" >/dev/null 2>&1
}

if [ "$WATCH" = 1 ]; then
  echo "== watch --json events (slow)"
  if [ -z "$RUNTIME" ] || [ -z "$DEVTYPE" ]; then read -r RUNTIME DEVTYPE < <(pick_runtime_and_type); fi
  [ -n "$DEVTYPE" ] || { echo "parity: no usable runtime" >&2; exit 2; }
  trap cleanup EXIT
  # watch slims every shut-down simulator on start; --set restricts nothing, so this
  # touches every simulator you own. Only run it when that is acceptable.
  watch_run go
  watch_run swift
  compare_one watch events
fi

echo
echo "compared $TOTAL, differing $DIFFS"
if [ "$DIFFS" -gt 0 ]; then
  echo "see $REPORT"
  exit 1
fi
