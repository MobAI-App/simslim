package simslim

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

func TestParseRuntimeRoot(t *testing.T) {
	out := []byte(`{"runtimes":[
		{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-5","runtimeRoot":"/r/iOS"},
		{"identifier":"com.apple.CoreSimulator.SimRuntime.tvOS-26-0","runtimeRoot":"/r/tvOS"}]}`)
	got, err := parseRuntimeRoot(out, "com.apple.CoreSimulator.SimRuntime.tvOS-26-0")
	if err != nil || got != "/r/tvOS" {
		t.Errorf("parseRuntimeRoot = %q, %v; want /r/tvOS", got, err)
	}
	if _, err := parseRuntimeRoot(out, "com.apple.CoreSimulator.SimRuntime.watchOS-26-0"); err == nil {
		t.Error("an unknown runtime must not resolve")
	}
}

func TestParseLaunchctlList(t *testing.T) {
	got := parseLaunchctlList("PID\tStatus\tLabel\n123\t0\tcom.apple.a\n-\t0\tcom.apple.b\n\ngarbage\n")
	want := map[string]bool{"com.apple.a": true, "com.apple.b": true}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("parseLaunchctlList = %v, want %v", got, want)
	}
}

func TestStillToStop(t *testing.T) {
	labels := []string{"a", "b", "c", "d"}
	disabled := map[string]bool{"a": true, "b": true, "c": true}
	loaded := map[string]bool{"b": true}
	if got := stillToStop(labels, disabled, loaded); !reflect.DeepEqual(got, []string{"b", "d"}) {
		t.Errorf("stillToStop = %v, want [b d]", got)
	}
}

// writeJobPlist writes a minimal launchd job plist whose Label key is label.
func writeJobPlist(t *testing.T, path, label string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	body := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>` + label + `</string></dict></plist>
`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

// A plist is only used when its own Label matches: a file named after one
// label but defining another would otherwise unload an unmanaged daemon.
func TestLaunchdJobPlistsMatchesTheLabelInside(t *testing.T) {
	root := t.TempDir()
	writeJobPlist(t, filepath.Join(root, "System/Library/LaunchDaemons/com.apple.a.plist"), "com.apple.a")
	writeJobPlist(t, filepath.Join(root, "System/Library/LaunchAgents/com.apple.b.plist"), "com.apple.b")
	writeJobPlist(t, filepath.Join(root, "System/Library/LaunchDaemons/com.apple.c.plist"), "com.apple.unmanaged")
	got := launchdJobPlists(context.Background(), root, []string{"com.apple.a", "com.apple.b", "com.apple.c", "com.apple.missing"}, readPlistLabel)
	want := map[string]string{
		"com.apple.a": filepath.Join(root, "System/Library/LaunchDaemons/com.apple.a.plist"),
		"com.apple.b": filepath.Join(root, "System/Library/LaunchAgents/com.apple.b.plist"),
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("launchdJobPlists = %v, want %v", got, want)
	}
}

// fakeBatchXcrun models a booted simulator's launchd with one file per label:
// $FAKE_DIS holds disable overrides, $FAKE_LOADED the loaded jobs. It answers
// `launchctl unload -w <plists...>` the way launchd does: override set, job
// gone. Labels listed in $FAKE_STUCK get the override but stay loaded, and
// FAKE_SLOW_UNLOAD makes every unload outlast its spawn timeout.
const fakeBatchXcrun = `#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_LOG"
case "$1 $2 $3" in
  "simctl list runtimes") printf '{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.%s","runtimeRoot":"%s"}]}\n' "$FAKE_RUNTIME" "$FAKE_ROOT"; exit 0 ;;
  "simctl list devices")  printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.%s":[{"udid":"%s","name":"Batch","state":"Booted","isAvailable":true,"dataPath":"/tmp/batch"}]}}\n' "$FAKE_RUNTIME" "$FAKE_UDID"; exit 0 ;;
esac
case "$1 $2" in
  "simctl boot"|"simctl bootstatus") exit 0 ;;
  "simctl spawn") shift 3 ;;
  *) exit 99 ;;
esac
verb=$2
case "$verb" in
  print-disabled) for f in "$FAKE_DIS"/*; do [ -e "$f" ] && printf '\t"%s" => disabled\n' "${f##*/}"; done ;;
  list) printf 'PID\tStatus\tLabel\n'; for f in "$FAKE_LOADED"/*; do [ -e "$f" ] && printf -- '-\t0\t%s\n' "${f##*/}"; done ;;
  unload)
    [ -n "$FAKE_SLOW_UNLOAD" ] && exec sleep 5
    shift 3
    for p in "$@"; do
      l=${p##*/}; l=${l%.plist}; : > "$FAKE_DIS/$l"
      grep -qx "$l" "$FAKE_STUCK" 2>/dev/null || rm -f "$FAKE_LOADED/$l"
    done ;;
  disable) l=${3#system/}; : > "$FAKE_DIS/$l" ;;
  bootout) l=${3#system/}; rm -f "$FAKE_LOADED/$l" ;;
  *) exit 99 ;;
esac
exit 0
`

// batchFake is a booted simulator whose launchd state lives in files, with a
// RuntimeRoot holding a job plist for every label except withoutPlist.
type batchFake struct {
	udid, dis, loaded, stuck, log string
}

func newBatchFake(t *testing.T, runtime string, labels []string, withoutPlist string) batchFake {
	t.Helper()
	dir := t.TempDir()
	f := batchFake{
		udid:   "00000000-0000-0000-0000-0000000000B1",
		dis:    filepath.Join(dir, "dis"),
		loaded: filepath.Join(dir, "loaded"),
		stuck:  filepath.Join(dir, "stuck"),
		log:    filepath.Join(dir, "calls.log"),
	}
	root := filepath.Join(dir, "RuntimeRoot")
	for _, d := range []string{f.dis, f.loaded} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for _, l := range labels {
		if err := os.WriteFile(filepath.Join(f.loaded, l), nil, 0o644); err != nil {
			t.Fatal(err)
		}
		if l != withoutPlist {
			writeJobPlist(t, filepath.Join(root, "System/Library/LaunchDaemons", l+".plist"), l)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "xcrun"), []byte(fakeBatchXcrun), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("FAKE_LOG", f.log)
	t.Setenv("FAKE_DIS", f.dis)
	t.Setenv("FAKE_LOADED", f.loaded)
	t.Setenv("FAKE_STUCK", f.stuck)
	t.Setenv("FAKE_ROOT", root)
	t.Setenv("FAKE_RUNTIME", runtime)
	t.Setenv("FAKE_UDID", f.udid)
	return f
}

// calls splits the logged xcrun calls into batch unloads and per-label spawns.
func (f batchFake) calls(t *testing.T) (unloads, perLabel []string) {
	t.Helper()
	log, err := os.ReadFile(f.log)
	if err != nil {
		t.Fatal(err)
	}
	for _, call := range strings.Split(strings.TrimSpace(string(log)), "\n") {
		switch {
		case strings.Contains(call, " launchctl unload "):
			unloads = append(unloads, call)
		case strings.Contains(call, " launchctl disable "), strings.Contains(call, " launchctl bootout "):
			perLabel = append(perLabel, call)
		}
	}
	return unloads, perLabel
}

// assertStopped checks that every label ends with an override and unloaded.
func (f batchFake) assertStopped(t *testing.T, labels []string) {
	t.Helper()
	for _, l := range labels {
		if _, err := os.Stat(filepath.Join(f.dis, l)); err != nil {
			t.Errorf("%s has no disable override", l)
		}
		if _, err := os.Stat(filepath.Join(f.loaded, l)); err == nil {
			t.Errorf("%s is still loaded", l)
		}
	}
}

func sortedLabels(set map[string]bool) []string {
	labels := make([]string, 0, len(set))
	for l := range set {
		labels = append(labels, l)
	}
	sort.Strings(labels)
	return labels
}

func TestNoRebootStopsEveryDaemonWithOneBatchSpawn(t *testing.T) {
	labels := sortedLabels(Profile{}.Desired())
	// Every job is loaded; all but one ship a plist, so that one must take the
	// per-label path.
	withoutPlist := labels[0]
	f := newBatchFake(t, "iOS-26-5", labels, withoutPlist)

	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, nil); err != nil {
		t.Fatalf("EnableSlimNoReboot: %v", err)
	}
	unloads, perLabel := f.calls(t)
	wantUnloads := (len(labels) - 1 + unloadChunk - 1) / unloadChunk
	if len(unloads) != wantUnloads {
		t.Errorf("%d unload spawns for %d plists, want %d", len(unloads), len(labels)-1, wantUnloads)
	}
	if len(perLabel) != 2 {
		t.Errorf("per-label spawns = %v, want only the disable and bootout of %s", perLabel, withoutPlist)
	}
	f.assertStopped(t, labels)
}

// A job that keeps its process after `unload -w` is disabled but still loaded;
// it must still get the per-label bootout.
func TestNoRebootBootsOutJobsTheBatchLeftLoaded(t *testing.T) {
	labels := sortedLabels(Profile{}.Desired())
	stuck := labels[3]
	f := newBatchFake(t, "iOS-26-5", labels, "")
	if err := os.WriteFile(f.stuck, []byte(stuck+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, nil); err != nil {
		t.Fatalf("EnableSlimNoReboot: %v", err)
	}
	_, perLabel := f.calls(t)
	want := []string{
		"simctl spawn " + f.udid + " launchctl disable system/" + stuck,
		"simctl spawn " + f.udid + " launchctl bootout system/" + stuck,
	}
	if !reflect.DeepEqual(perLabel, want) {
		t.Errorf("per-label spawns = %v, want %v", perLabel, want)
	}
	f.assertStopped(t, labels)
}

// Without a RuntimeRoot there are no plists to batch, so every label takes the
// per-label path and the slim still succeeds.
func TestNoRebootFallsBackWithoutRuntimeRoot(t *testing.T) {
	labels := sortedLabels(Profile{}.Desired())
	f := newBatchFake(t, "iOS-26-5", labels, "")
	t.Setenv("FAKE_ROOT", "")

	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, nil); err != nil {
		t.Fatalf("EnableSlimNoReboot: %v", err)
	}
	unloads, perLabel := f.calls(t)
	if len(unloads) != 0 || len(perLabel) != 2*len(labels) {
		t.Errorf("%d unload and %d per-label spawns, want 0 and %d", len(unloads), len(perLabel), 2*len(labels))
	}
	f.assertStopped(t, labels)
}

// A chunk that outlasts its spawn timeout ends the batch at once, so a slow
// host keeps its remaining budget for the per-label path.
func TestNoRebootStopsBatchingAfterASlowChunk(t *testing.T) {
	labels := sortedLabels(Profile{}.Desired())
	f := newBatchFake(t, "iOS-26-5", labels, "")
	t.Setenv("FAKE_SLOW_UNLOAD", "1")
	previous := SpawnTimeout
	SpawnTimeout = 300 * time.Millisecond
	t.Cleanup(func() { SpawnTimeout = previous })

	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, nil); err != nil {
		t.Fatalf("EnableSlimNoReboot: %v", err)
	}
	unloads, perLabel := f.calls(t)
	if len(unloads) != 1 {
		t.Errorf("%d unload spawns after the first one timed out, want 1", len(unloads))
	}
	if len(perLabel) != 2*len(labels) {
		t.Errorf("%d per-label spawns, want %d", len(perLabel), 2*len(labels))
	}
	f.assertStopped(t, labels)
}

// A second run on a device that is already slim has nothing to stop: it spawns
// no unload and no per-label transition, and says so instead of claiming a batch.
func TestNoRebootOnASlimDeviceStopsNothing(t *testing.T) {
	labels := sortedLabels(Profile{}.Desired())
	f := newBatchFake(t, "iOS-26-5", labels, "")
	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, nil); err != nil {
		t.Fatalf("first EnableSlimNoReboot: %v", err)
	}
	if err := os.Remove(f.log); err != nil {
		t.Fatal(err)
	}

	var lines []string
	report := Reporter(func(s string) { lines = append(lines, s) })
	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, report); err != nil {
		t.Fatalf("second EnableSlimNoReboot: %v", err)
	}
	unloads, perLabel := f.calls(t)
	if len(unloads) != 0 || len(perLabel) != 0 {
		t.Errorf("%d unload and %d per-label spawns on a slim device, want none", len(unloads), len(perLabel))
	}
	out := strings.Join(lines, "\n")
	if strings.Contains(out, "stopped in one batch") || !strings.Contains(out, "already stopped") {
		t.Errorf("report on a slim device = %q, want the already-stopped line", out)
	}
	f.assertStopped(t, labels)
}

// The batch only unloads the device's own desired labels, so visionOS keeps
// mobileassetd (and with it the surroundings) running.
func TestNoRebootBatchKeepsVisionMobileAssetsRunning(t *testing.T) {
	const label = "com.apple.mobileassetd"
	f := newBatchFake(t, "xrOS-27-0", sortedLabels(Profile{}.Desired()), "")

	if _, err := EnableSlimNoReboot(context.Background(), "default", f.udid, Profile{}, nil); err != nil {
		t.Fatalf("EnableSlimNoReboot: %v", err)
	}
	unloads, perLabel := f.calls(t)
	for _, call := range append(unloads, perLabel...) {
		if strings.Contains(call, label) {
			t.Errorf("visionOS slim passed %s to launchctl", label)
		}
	}
	if _, err := os.Stat(filepath.Join(f.loaded, label)); err != nil {
		t.Errorf("%s is no longer loaded on visionOS", label)
	}
	if _, err := os.Stat(filepath.Join(f.dis, label)); err == nil {
		t.Errorf("%s got a disable override on visionOS", label)
	}
}
