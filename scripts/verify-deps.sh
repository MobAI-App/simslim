#!/bin/zsh
# Verifies that the Swift port uses no third-party code and no network.
# Read-only except for building into swift/.build. Run it by hand:
#
#   make verify-deps                       # all checks
#   scripts/verify-deps.sh --update-libs   # rewrite swift/expected-libs.txt, then review the diff
#   scripts/verify-deps.sh --no-binary     # source-level checks only (no build)
#
# Exit status is non-zero if any check fails.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_DIR="$ROOT_DIR/swift"
GUI_DIR="$ROOT_DIR/gui"
SELF="scripts/verify-deps.sh"
EXPECTED_LIBS="$SWIFT_DIR/expected-libs.txt"

UPDATE_LIBS=0
CHECK_BINARY=1
for arg in "$@"; do
  case "$arg" in
    --update-libs) UPDATE_LIBS=1 ;;
    --no-binary) CHECK_BINARY=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 64 ;;
  esac
done

# Never name a zsh loop variable `path`: it is tied to PATH.
for tool in find grep awk sort diff otool nm strings swift; do
  command -v "$tool" >/dev/null 2>&1 || { print -u2 -- "verify-deps: required tool not found: $tool"; exit 70 }
done

# grep that treats "no match" (1) as empty output but any real error (>1) as fatal,
# so a broken search can never read as a clean result.
hits() {
  local rc=0
  grep "$@" || rc=$?
  if (( rc > 1 )); then
    print -u2 -- "verify-deps: grep failed (status $rc): grep $*"
    exit 70
  fi
  return 0
}

FAILED=0
fail() { print -u2 -- "  FAIL: $*"; FAILED=1 }
ok() { print -- "  ok: $*" }
section() { print -- "\n[$1]" }

# Modules each tree may import. Everything here ships with Xcode.
ALLOWED_SOURCES=(Foundation Darwin Dispatch SimSlimKit)
ALLOWED_TESTS=(Foundation Darwin Dispatch SimSlimKit XCTest Testing)
ALLOWED_GUI=(Foundation AppKit SwiftUI)

# Prints "<file>: <module>" for each import in the given directory.
list_imports() {
  local dir="$1" file
  [[ -d "$dir" ]] || return 0
  find "$dir" -name '*.swift' -not -path '*/.build/*' | sort | while read -r file; do
    awk -v f="${file#$ROOT_DIR/}" '
      /^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*((public|internal|package)[[:space:]]+)?import[[:space:]]/ {
        n = split($0, w, /[[:space:]]+/)
        for (i = 1; i <= n; i++) if (w[i] == "import") { j = i + 1; break }
        if (w[j] ~ /^(struct|class|enum|protocol|typealias|func|var|let)$/) j++
        split(w[j], m, ".")
        print f ": " m[1]
      }' "$file"
  done
}

check_imports() {
  local label="$1" dir="$2"; shift 2
  local -a allowed=("$@")
  local line module bad=0
  while read -r line; do
    [[ -n "$line" ]] || continue
    module="${line##*: }"
    if (( ${allowed[(Ie)$module]} == 0 )); then
      fail "$label imports '$module' (${line%%:*}); allowed: ${allowed[*]}"
      bad=1
    fi
  done < <(list_imports "$dir")
  (( bad )) || ok "$label imports only: ${allowed[*]}"
}

# ------------------------------------------------------------------ canary
# Prove the searches can see the code: these patterns must match known lines.
section "0. Canary (the searches can see the code)"
[[ -n "$(hits -rn 'enum Executable' "$SWIFT_DIR/Sources")" ]] \
  && ok "found enum Executable in swift/Sources" || fail "canary: enum Executable not found"
[[ -n "$(hits -rn 'import Foundation' "$SWIFT_DIR/Sources")" ]] \
  && ok "found import Foundation in swift/Sources" || fail "canary: no imports found"
[[ -n "$(list_imports "$GUI_DIR")" ]] \
  && ok "list_imports sees the gui imports" || fail "canary: list_imports returned nothing for gui"
(( FAILED )) && { print -u2 -- "verify-deps: canary failed, aborting"; exit 70 }

# ---------------------------------------------------------------- 1 packages
section "1. No packages, vendored code, or plugins"
PKG="$SWIFT_DIR/Package.swift"
if [[ ! -f "$PKG" ]]; then
  fail "missing $PKG"
else
  pkg_hits="$(hits -nE '\.package\(|\.binaryTarget|\.plugin|\.systemLibrary' "$PKG")"
  if [[ -n "$pkg_hits" ]]; then
    print -u2 -- "$pkg_hits"
    fail "Package.swift declares a package, binary target, plugin, or system library"
  else
    ok "Package.swift declares no packages, binary targets, or plugins"
  fi
fi
artifacts_ok=1
for artifact in "$SWIFT_DIR/Package.resolved" "$SWIFT_DIR/Packages" "$SWIFT_DIR/vendor" \
                "$ROOT_DIR/Package.swift" "$ROOT_DIR/Package.resolved" \
                "$ROOT_DIR/Podfile" "$ROOT_DIR/Cartfile"; do
  if [[ -e "$artifact" ]]; then fail "unexpected dependency artifact: ${artifact#$ROOT_DIR/}"; artifacts_ok=0; fi
done
# SwiftPM creates an empty checkouts directory even with no dependencies.
if [[ -d "$SWIFT_DIR/.build/checkouts" && -n "$(ls -A "$SWIFT_DIR/.build/checkouts")" ]]; then
  fail "swift/.build/checkouts is not empty: SwiftPM fetched something"; artifacts_ok=0
fi
(( artifacts_ok )) && ok "no Package.resolved, checkouts, Packages/, vendor/, Podfile, or Cartfile"

# ---------------------------------------------------------------- 2 imports
section "2. Imports are on the allowlist"
check_imports "swift/Sources" "$SWIFT_DIR/Sources" "${ALLOWED_SOURCES[@]}"
check_imports "swift/Tests" "$SWIFT_DIR/Tests" "${ALLOWED_TESTS[@]}"
check_imports "gui" "$GUI_DIR" "${ALLOWED_GUI[@]}"

# ---------------------------------------------------------------- 3 network
section "3. No network APIs in source"
NET_PATTERN='URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWPathMonitor|CFNetwork|CFSocket|CFStream|InputStream|OutputStream|WKWebView|getaddrinfo|socket\(|connect\(|URL\(string:|http://|https://|ftp://'
net_hits="$(hits -rnE "$NET_PATTERN" "$SWIFT_DIR/Sources" "$GUI_DIR" --include='*.swift')"
if [[ -n "$net_hits" ]]; then
  print -u2 -- "$net_hits"
  fail "network-capable API or URL found in source (above)"
else
  ok "no URLSession, sockets, Network framework, or URLs in source"
fi

# Data(contentsOf:) and friends fetch remote URLs too. Only local reads are
# allowed, which means the line must build its URL with fileURLWithPath.
remote_read_hits="$(hits -rnE '(Data|String|NSData|NSString|NSDictionary|NSArray|XMLDocument)\((contentsOf|contentsOfURL):|dataTask|downloadTask' "$SWIFT_DIR/Sources" "$GUI_DIR" --include='*.swift' \
  | hits -v 'fileURLWithPath')"
if [[ -n "$remote_read_hits" ]]; then
  print -u2 -- "$remote_read_hits"
  fail "contentsOf:/download call that is not a fileURLWithPath read (above)"
else
  ok "every contentsOf: read is a local fileURLWithPath"
fi

# ---------------------------------------------------------------- 4 subprocess
section "4. Subprocesses go through Subprocess.swift only"
SUBPROC="$SWIFT_DIR/Sources/SimSlimKit/Subprocess.swift"
spawn_hits="$(hits -rnE '\bProcess\(|NSTask|posix_spawn|\bpopen\(|\bsystem\(|\bexecv|\bfork\(|/bin/(ba|z)?sh' \
  "$SWIFT_DIR/Sources" --include='*.swift' --exclude=Subprocess.swift)"
if [[ -n "$spawn_hits" ]]; then
  print -u2 -- "$spawn_hits"
  fail "process spawning outside Subprocess.swift (above)"
else
  ok "Process/posix_spawn/popen/system only in Subprocess.swift"
fi
path_hits="$(hits -rnE '"/(usr/(s)?bin|bin|sbin|opt|Applications)/' "$SWIFT_DIR/Sources" --include='*.swift' \
  --exclude=Subprocess.swift)"
if [[ -n "$path_hits" ]]; then
  print -u2 -- "$path_hits"
  fail "hard-coded executable path outside Subprocess.swift (above)"
else
  ok "no executable paths outside the Executable enum"
fi
if [[ -n "$(hits -nE 'getenv|environment\[|\.environment|/usr/bin/env|"PATH"' "$SUBPROC")" ]]; then
  fail "Subprocess.swift reads the environment or PATH"
else
  ok "Subprocess.swift reads no environment and does no PATH lookup"
fi

# ---------------------------------------------------------------- 7 fetching
section "5. Build files fetch nothing"
fetch_hits="$(cd "$ROOT_DIR" && hits -nE 'curl|wget|git clone|git submodule|http://|https://|brew install|pip install|npm install' \
  swift/Package.swift Makefile scripts/build-app.sh | hits -v '^[^:]*:[0-9]*:[[:space:]]*echo ')"
if [[ -n "$fetch_hits" ]]; then
  print -u2 -- "$fetch_hits"
  fail "build files reference a download or installer (above)"
else
  ok "swift/Package.swift, Makefile, and scripts/build-app.sh fetch nothing"
fi

# ------------------------------------------------------------ binary checks
if (( CHECK_BINARY )); then
  section "6. Release binary"
  (cd "$SWIFT_DIR" && swift build -c release >/dev/null 2>&1) || { fail "swift build -c release failed"; }
  BIN="$SWIFT_DIR/.build/release/simslim"
  if [[ ! -x "$BIN" ]]; then
    fail "release binary not found at ${BIN#$ROOT_DIR/}"
  else
    # Linked libraries must all be system libraries.
    libs="$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | sort)"
    non_system="$(print -r -- "$libs" | hits -vE '^(/usr/lib/|/System/Library/)')"
    if [[ -n "$non_system" ]]; then
      print -u2 -- "$non_system"
      fail "binary links a non-system library (above)"
    else
      ok "every linked library is under /usr/lib or /System/Library"
    fi
    if (( UPDATE_LIBS )); then
      print -r -- "$libs" > "$EXPECTED_LIBS"
      ok "rewrote ${EXPECTED_LIBS#$ROOT_DIR/} (review the diff)"
    elif [[ -f "$EXPECTED_LIBS" ]]; then
      if diff <(print -r -- "$libs") "$EXPECTED_LIBS" >/dev/null; then
        ok "linked libraries match swift/expected-libs.txt"
      else
        diff <(print -r -- "$libs") "$EXPECTED_LIBS" >&2 || true
        fail "linked libraries differ from swift/expected-libs.txt"
      fi
    else
      fail "swift/expected-libs.txt is missing (run with --update-libs, then review it)"
    fi

    # Undefined symbols that would indicate networking.
    NET_SYMBOLS='NSURLSession|NSURLConnection|CFNetwork|nw_connection|nw_listener|_getaddrinfo|_socket$|_connect$'
    net_syms="$(nm -u "$BIN" | hits -E "$NET_SYMBOLS")"
    if [[ -n "$net_syms" ]]; then
      print -u2 -- "$net_syms"
      fail "binary imports network symbols (above)"
    else
      ok "no network symbols among the binary's imports"
    fi

    # Test-only hooks must never ship. By convention they are named SIMSLIM_TEST_*.
    if [[ -n "$(strings -a "$BIN" | hits 'SIMSLIM_TEST_')" ]]; then
      fail "release binary contains a SIMSLIM_TEST_ hook"
    else
      ok "no SIMSLIM_TEST_ hooks in the release binary"
    fi

    # Behavior check: the binary still works with all network access denied.
    if command -v sandbox-exec >/dev/null 2>&1; then
      if out="$(sandbox-exec -p '(version 1)(allow default)(deny network*)' "$BIN" --version 2>&1)"; then
        ok "runs with network denied: $out"
      else
        fail "binary failed under sandbox-exec with network denied: $out"
      fi
    else
      print -- "  skip: sandbox-exec not available"
    fi
  fi
fi

print -- ""
if (( FAILED )); then
  print -u2 -- "verify-deps: FAILED"
  exit 1
fi
print -- "verify-deps: all checks passed"
