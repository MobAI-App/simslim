package simslim

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"
)

const (
	bootedClone          = `{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-1":[{"udid":"AAAA","name":"clone-1","state":"Booted","isAvailable":true,"dataPath":"/tmp/a"}]}}`
	shutdownClone        = `{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-1":[{"udid":"AAAA","name":"clone-1","state":"Shutdown","isAvailable":true,"dataPath":"/tmp/a"}]}}`
	bootedAndStoppedPair = `{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-1":[{"udid":"AAAA","name":"clone-1","state":"Booted","isAvailable":true,"dataPath":"/tmp/a"},{"udid":"BBBB","name":"clone-2","state":"Shutdown","isAvailable":true,"dataPath":"/tmp/b"}]}}`
)

// fakeDeviceList puts a fake xcrun on PATH that serves the device list from a
// file, and returns the function that rewrites it so a test can change a
// device's state between scans.
func fakeDeviceList(t *testing.T, devices string) func(string) {
	t.Helper()
	dir := t.TempDir()
	statePath := filepath.Join(dir, "devices.json")
	xcrunPath := filepath.Join(dir, "xcrun")
	script := `#!/bin/sh
if [ "$*" = "simctl list devices -j" ]; then
  cat "$SIMSLIM_FAKE_DEVICES"
  exit 0
fi
exit 0
`
	if err := os.WriteFile(xcrunPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SIMSLIM_FAKE_DEVICES", statePath)
	rewrite := func(devices string) {
		t.Helper()
		if err := os.WriteFile(statePath, []byte(devices), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	rewrite(devices)
	return rewrite
}

func newTestWatcher(slim slimStrategy, report Reporter) *watcher {
	return &watcher{report: report, slim: slim, seen: map[string]bool{}}
}

// TestWatchSlimsEachBootedDeviceOnce verifies the scan slims a booted device
// exactly once and never touches a shutdown one, so a steady poll does not
// re-slim clones it already handled.
func TestWatchSlimsEachBootedDeviceOnce(t *testing.T) {
	fakeDeviceList(t, bootedAndStoppedPair)

	var mu sync.Mutex
	slimmed := map[string]int{}
	fake := func(_ context.Context, _, udid string, _ Profile, _ Reporter) (bool, error) {
		mu.Lock()
		slimmed[udid]++
		mu.Unlock()
		return true, nil
	}

	w := newTestWatcher(fake, nil)
	for i := 0; i < 3; i++ { // repeated scans must not re-slim
		w.scan(context.Background())
		w.wg.Wait()
	}

	mu.Lock()
	defer mu.Unlock()
	if slimmed["AAAA"] != 1 {
		t.Fatalf("booted device slimmed %d times, want 1", slimmed["AAAA"])
	}
	if slimmed["BBBB"] != 0 {
		t.Fatalf("shutdown device slimmed %d times, want 0", slimmed["BBBB"])
	}
}

// TestWatchReslimsDeviceAfterShutdown covers the boot session the no-reboot
// slim lives in: on iOS below 18.5 a device that shuts down comes back stock,
// so watch must slim it again instead of skipping it for the rest of the run.
func TestWatchReslimsDeviceAfterShutdown(t *testing.T) {
	rewrite := fakeDeviceList(t, bootedClone)

	var mu sync.Mutex
	slims := 0
	fake := func(_ context.Context, _, _ string, _ Profile, _ Reporter) (bool, error) {
		mu.Lock()
		slims++
		mu.Unlock()
		return true, nil
	}

	w := newTestWatcher(fake, nil)
	for _, devices := range []string{bootedClone, shutdownClone, bootedClone} {
		rewrite(devices)
		w.scan(context.Background())
		w.wg.Wait()
	}

	mu.Lock()
	defer mu.Unlock()
	if slims != 2 {
		t.Fatalf("device slimmed %d times across a shutdown and a second boot, want 2", slims)
	}
}

// TestWatchRetriesSlimAfterError verifies a failed slim is retried on the next
// scan: a transient launchctl failure must not leave that clone stock for the
// whole test run. A slim that succeeds is still never repeated.
func TestWatchRetriesSlimAfterError(t *testing.T) {
	fakeDeviceList(t, bootedClone)

	var mu sync.Mutex
	attempts := 0
	fake := func(_ context.Context, _, _ string, _ Profile, _ Reporter) (bool, error) {
		mu.Lock()
		attempts++
		first := attempts == 1
		mu.Unlock()
		if first {
			return false, errors.New("launchctl disable failed")
		}
		return true, nil
	}

	w := newTestWatcher(fake, nil)
	for i := 0; i < 3; i++ {
		w.scan(context.Background())
		w.wg.Wait()
	}

	mu.Lock()
	defer mu.Unlock()
	if attempts != 2 {
		t.Fatalf("slim attempted %d times, want 2 (one failure, one retry)", attempts)
	}
}

// TestWatchPrefixesDeviceProgress verifies the per-device messages of the slim
// reach the caller, tagged with the UDID they came from.
func TestWatchPrefixesDeviceProgress(t *testing.T) {
	fakeDeviceList(t, bootedClone)

	var mu sync.Mutex
	var lines []string
	report := Reporter(func(msg string) {
		mu.Lock()
		lines = append(lines, msg)
		mu.Unlock()
	})
	fake := func(_ context.Context, _, _ string, _ Profile, deviceReport Reporter) (bool, error) {
		deviceReport.report("Leaving 3 services disabled beyond this profile.")
		return true, nil
	}

	w := newTestWatcher(fake, report)
	w.scan(context.Background())
	w.wg.Wait()

	mu.Lock()
	defer mu.Unlock()
	const want = "watch: AAAA: Leaving 3 services disabled beyond this profile."
	if !slices.Contains(lines, want) {
		t.Fatalf("reported lines = %q, want one %q", lines, want)
	}
}

// TestWatchWaitsForInFlightSlims verifies Watch does not return while a slim is
// still running, so an importer holds no goroutine it cannot see.
func TestWatchWaitsForInFlightSlims(t *testing.T) {
	fakeDeviceList(t, bootedClone)

	started := make(chan struct{}, 1)
	release := make(chan struct{})
	fake := func(_ context.Context, _, _ string, _ Profile, _ Reporter) (bool, error) {
		started <- struct{}{}
		<-release
		return true, nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	returned := make(chan error, 1)
	go func() { returned <- watch(ctx, Profile{}, time.Millisecond, nil, fake) }()

	<-started
	cancel()
	select {
	case <-returned:
		t.Fatal("watch returned while a slim was still in flight")
	case <-time.After(50 * time.Millisecond):
	}

	close(release)
	select {
	case err := <-returned:
		if err != nil {
			t.Fatalf("watch() = %v, want nil", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("watch did not return after the in-flight slim finished")
	}
}
