package simslim

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestEnableSlimThisBootNeverReboots drives EnableSlimThisBoot against a fake
// xcrun on an iOS 18.3 device: every profiled label gets a disable and a
// bootout, including com.apple.b whose override already exists (a previous run
// may have failed before booting it out), a bootout of an already-missing
// service (exit 3) counts as done, and no shutdown or second boot ever happens.
func TestEnableSlimThisBootNeverReboots(t *testing.T) {
	const udid = "00000000-0000-0000-0000-000000000038"
	dir := t.TempDir()
	logPath := filepath.Join(dir, "xcrun.log")
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$SIMSLIM_XCRUN_LOG"
case "$*" in
  "simctl list devices -j")
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-3":[{"udid":"00000000-0000-0000-0000-000000000038","name":"Issue 38","state":"Booted","isAvailable":true,"dataPath":"/tmp/issue-38"}]}}' ;;
  "simctl boot "*) echo "Unable to boot device in current state: Booted" >&2; exit 1 ;;
  "simctl bootstatus "*) exit 0 ;;
  *"launchctl print-disabled system")
    printf '\t"%s" => disabled\n' com.apple.b
    if [ -f "$SIMSLIM_XCRUN_LOG.applied" ]; then
      printf '\t"%s" => disabled\n' com.apple.a
    fi ;;
  *"/bin/sh -c "*) exit 0 ;;
  *"launchctl disable system/"*) exit 0 ;;
  *"launchctl bootout system/com.apple.a") : > "$SIMSLIM_XCRUN_LOG.applied"; exit 0 ;;
  *"launchctl bootout system/com.apple.b") echo "Boot-out failed: 3: No such process" >&2; exit 3 ;;
  *) exit 99 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "xcrun"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SIMSLIM_XCRUN_LOG", logPath)
	saved := Categories
	Categories = []Category{{ID: "t", Name: "t", Labels: []string{"com.apple.a", "com.apple.b"}, ApproxMemoryMB: 1}}
	defer func() { Categories = saved }()

	changed, err := EnableSlimThisBoot(context.Background(), "default", udid, Profile{}, nil)
	if err != nil || !changed {
		t.Fatalf("EnableSlimThisBoot = (%t, %v), want (true, nil)", changed, err)
	}
	log, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	calls := string(log)
	for _, want := range []string{
		"launchctl disable system/com.apple.a", "launchctl bootout system/com.apple.a",
		"launchctl disable system/com.apple.b", "launchctl bootout system/com.apple.b",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("missing %q in xcrun calls:\n%s", want, calls)
		}
	}
	for _, forbidden := range []string{"simctl shutdown", "launchctl enable"} {
		if strings.Contains(calls, forbidden) {
			t.Errorf("unexpected %q in xcrun calls:\n%s", forbidden, calls)
		}
	}
	if n := strings.Count(calls, "simctl boot "); n != 1 {
		t.Errorf("simctl boot called %d times, want 1 (no reboot):\n%s", n, calls)
	}
}
