package simslim

import (
	"context"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// fakeXcrunScript logs every call, answers the device lookup, and hands any
// `simctl spawn` straight to the stub launchctl below, so the transitions run
// as written instead of being matched by a pattern.
const fakeXcrunScript = `#!/bin/sh
printf '%s\n' "$*" >> "$SIMSLIM_XCRUN_LOG"
case "$1 $2" in
  "simctl list")
    printf '%s\n' "$SIMSLIM_TEST_DEVICES" | sed "s/@STATE@/$(cat "$SIMSLIM_TEST_STATE")/"
    ;;
  "simctl spawn")
    shift 3
    export DYLD_ROOT_PATH="$SIMULATOR_ROOT"
    exec "$@"
    ;;
  "simctl boot")
    printf Booted > "$SIMSLIM_TEST_STATE"
    ;;
  "simctl shutdown")
    printf Shutdown > "$SIMSLIM_TEST_STATE"
    ;;
  "simctl bootstatus")
    ;;
  *)
    exit 99
    ;;
esac
`

// fakeLaunchctlScript is a stand-in launchd. Live overrides are one file per
// label, so applyDelta's concurrent workers cannot race each other, and
// print-disabled renders the union of those and the offline store — which is
// how the real launchd_sim behaves, having read the store when it started.
// SIMSLIM_TEST_IGNORE_STORE models a runtime that does not honour the store.
const fakeLaunchctlScript = `#!/bin/sh
label=${2#system/}
case "$1" in
  print-disabled)
    if [ "$SIMSLIM_TEST_IGNORE_STORE" != 1 ] && [ -f "$SIMSLIM_TEST_STORE" ]; then
      awk '
        /<key>/  { sub(/.*<key>/, ""); sub(/<\/key>.*/, ""); l=$0; next }
        /<true\/>/  { if (l != "") printf "\t\"%s\" => disabled\n", l; l="" }
        /<false\/>/ { l="" }
      ' "$SIMSLIM_TEST_STORE"
    fi
    for f in "$SIMSLIM_TEST_LIVE"/*; do
      [ -e "$f" ] && printf '\t"%s" => disabled\n' "${f##*/}"
    done
    ;;
  disable) mkdir -p "$SIMSLIM_TEST_LIVE" && : > "$SIMSLIM_TEST_LIVE/$label" ;;
  enable)  rm -f "$SIMSLIM_TEST_LIVE/$label" ;;
  bootout) exit 3 ;;
  *) exit 99 ;;
esac
exit 0
`

// fakeSimctl puts the stub toolchain on PATH for one device and returns the
// path of the xcrun call log.
func fakeSimctl(t *testing.T, udid, runtime, state string) string {
	t.Helper()
	dir := t.TempDir()
	for name, script := range map[string]string{"xcrun": fakeXcrunScript, "launchctl": fakeLaunchctlScript} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	logPath := filepath.Join(dir, "xcrun.log")
	// @STATE@ is substituted from the state file, so a boot or shutdown the
	// code under test issues is reflected by the next `simctl list`.
	devices := `{"devices":{"com.apple.CoreSimulator.SimRuntime.` + runtime + `":[{"udid":"` + udid +
		`","name":"Offline Probe","state":"@STATE@","isAvailable":true,"dataPath":"` + dir + `/data"}]}}`
	statePath := filepath.Join(dir, "state")
	if err := os.WriteFile(statePath, []byte(state), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SIMSLIM_TEST_STATE", statePath)
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SIMSLIM_XCRUN_LOG", logPath)
	t.Setenv("SIMSLIM_TEST_DEVICES", devices)
	t.Setenv("SIMSLIM_TEST_STORE", disabledStorePath(udid))
	t.Setenv("SIMSLIM_TEST_LIVE", filepath.Join(dir, "live"))
	// simctl exports this into a spawned process alongside DYLD_ROOT_PATH.
	t.Setenv("SIMULATOR_ROOT", dir+"/runtime")
	return logPath
}

func xcrunCalls(t *testing.T, logPath string) []string {
	t.Helper()
	log, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Split(strings.TrimSpace(string(log)), "\n")
}

// twoSlimmableLabels returns a stable pair of real managed labels.
func twoSlimmableLabels(t *testing.T) []string {
	t.Helper()
	var labels []string
	for l := range SlimmableSet() {
		labels = append(labels, l)
	}
	sort.Strings(labels)
	if len(labels) < 2 {
		t.Fatalf("need at least 2 slimmable labels, got %d", len(labels))
	}
	return labels[:2]
}

func TestEnsureSlimsAShutdownDeviceWithoutLaunchctlSpawns(t *testing.T) {
	const udid = "00000000-0000-0000-0000-0000000000E1"
	useTempStoreRoot(t)
	logPath := fakeSimctl(t, udid, "iOS-26-5", "Shutdown")
	labels := twoSlimmableLabels(t)

	changed, err := ensure(context.Background(), "default", udid, map[string]bool{labels[0]: true, labels[1]: true}, nil)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if !changed {
		t.Error("ensure reported no change after slimming a stock device")
	}

	disabled, err := readDisabledStore(udid)
	if err != nil {
		t.Fatalf("readDisabledStore: %v", err)
	}
	for _, l := range labels {
		if !disabled[l] {
			t.Errorf("label %q not disabled in the store; store = %v", l, disabled)
		}
	}

	// One boot, no launchctl transitions, no reboot: that is the whole win.
	want := []string{
		"simctl list devices -j",
		"simctl boot " + udid,
		"simctl bootstatus " + udid + " -b",
		"simctl spawn " + udid + " launchctl print-disabled system",
	}
	if got := xcrunCalls(t, logPath); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("xcrun calls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestEnsureFallsBackWhenTheStoreCannotBeWritten(t *testing.T) {
	const udid = "00000000-0000-0000-0000-0000000000E3"
	root := useTempStoreRoot(t)
	// A regular file where the store root should be: every write under it fails,
	// which stands in for a sandboxed or permission-denied host.
	blocked := filepath.Join(root, "blocked")
	if err := os.WriteFile(blocked, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	disabledStoreRoot = blocked
	logPath := fakeSimctl(t, udid, "iOS-26-5", "Shutdown")
	labels := twoSlimmableLabels(t)

	changed, err := ensure(context.Background(), "default", udid, map[string]bool{labels[0]: true, labels[1]: true}, nil)
	if err != nil {
		t.Fatalf("ensure did not fall back when the store was unwritable: %v", err)
	}
	if !changed {
		t.Error("ensure reported no change after slimming a stock device")
	}
	if calls := strings.Join(xcrunCalls(t, logPath), "\n"); !strings.Contains(calls, "launchctl") {
		t.Errorf("expected a fallback to launchctl, got:\n%s", calls)
	}
}

func TestEnsureFallsBackToLaunchctlWhenTheRuntimeIgnoresTheStore(t *testing.T) {
	const udid = "00000000-0000-0000-0000-0000000000E2"
	useTempStoreRoot(t)
	logPath := fakeSimctl(t, udid, "iOS-26-5", "Shutdown")
	t.Setenv("SIMSLIM_TEST_IGNORE_STORE", "1")
	labels := twoSlimmableLabels(t)

	changed, err := ensure(context.Background(), "default", udid, map[string]bool{labels[0]: true, labels[1]: true}, nil)
	if err != nil {
		t.Fatalf("ensure did not fall back to the supported path: %v", err)
	}
	if !changed {
		t.Error("ensure reported no change after slimming a stock device")
	}

	calls := strings.Join(xcrunCalls(t, logPath), "\n")
	if !strings.Contains(calls, "launchctl") || !strings.Contains(calls, "simctl shutdown "+udid) {
		t.Errorf("expected a fallback to launchctl plus a reboot, got:\n%s", calls)
	}
}

func TestEnsureSlimsABootedDeviceThroughTheOfflineStore(t *testing.T) {
	const udid = "00000000-0000-0000-0000-0000000000E4"
	useTempStoreRoot(t)
	logPath := fakeSimctl(t, udid, "iOS-26-5", "Booted")
	labels := twoSlimmableLabels(t)

	changed, err := ensure(context.Background(), "default", udid, map[string]bool{labels[0]: true, labels[1]: true}, nil)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if !changed {
		t.Error("ensure reported no change after slimming a stock device")
	}

	// A booted device owes a shutdown and a boot either way, so spending them
	// first buys the whole offline path: no launchctl transition at all.
	want := []string{
		"simctl list devices -j",
		"simctl spawn " + udid + " launchctl print-disabled system",
		"simctl shutdown " + udid,
		"simctl list devices -j",
		"simctl boot " + udid,
		"simctl bootstatus " + udid + " -b",
		"simctl spawn " + udid + " launchctl print-disabled system",
	}
	if got := xcrunCalls(t, logPath); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("xcrun calls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestEnsureLeavesAnAlreadySlimBootedDeviceAlone(t *testing.T) {
	const udid = "00000000-0000-0000-0000-0000000000E5"
	useTempStoreRoot(t)
	logPath := fakeSimctl(t, udid, "iOS-26-5", "Booted")
	labels := twoSlimmableLabels(t)
	desired := map[string]bool{labels[0]: true, labels[1]: true}
	if err := writeDisabledStore(udid, labels, nil); err != nil {
		t.Fatal(err)
	}

	changed, err := ensure(context.Background(), "default", udid, desired, nil)
	if err != nil {
		t.Fatalf("ensure: %v", err)
	}
	if changed {
		t.Error("ensure reported a change on a device that already matched the profile")
	}

	// Reading the live state is enough to prove there is nothing to do; a
	// matching profile must not cost a shutdown or a reboot.
	want := []string{
		"simctl list devices -j",
		"simctl spawn " + udid + " launchctl print-disabled system",
	}
	if got := xcrunCalls(t, logPath); strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("xcrun calls =\n%s\nwant\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}
