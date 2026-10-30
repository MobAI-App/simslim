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
	return &watcher{report: report, slim: slim, seen: map[string]bool{}, seeded: map[string]bool{}}
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

// TestWatchSeedsShutdownDeviceBeforeBoot verifies a shut-down device is slimmed
// ahead of its boot once, not on every scan, is handed to the after-boot slim
// when it boots, and is checked again after its next shutdown.
func TestWatchSeedsShutdownDeviceBeforeBoot(t *testing.T) {
	rewrite := fakeDeviceList(t, shutdownClone)

	var mu sync.Mutex
	slims := 0
	fake := func(_ context.Context, _, _ string, _ Profile, _ Reporter) (bool, error) {
		mu.Lock()
		slims++
		mu.Unlock()
		return true, nil
	}
	var seeds []string
	w := newTestWatcher(fake, nil)
	w.preslim = func(d Device, _ Profile) (int, error) {
		seeds = append(seeds, d.UDID+" "+d.State)
		return 3, nil
	}
	for _, devices := range []string{shutdownClone, shutdownClone, bootedClone, shutdownClone, shutdownClone} {
		rewrite(devices)
		w.scan(context.Background())
		w.wg.Wait()
	}

	if want := []string{"AAAA Shutdown", "AAAA Shutdown"}; !slices.Equal(seeds, want) {
		t.Fatalf("seeded %q, want %q (once per shutdown)", seeds, want)
	}
	mu.Lock()
	defer mu.Unlock()
	if slims != 1 {
		t.Fatalf("after-boot slim ran %d times, want 1", slims)
	}
}

// TestWatchRetriesSeedAfterError verifies a store that could not be written is
// tried again on the next scan.
func TestWatchRetriesSeedAfterError(t *testing.T) {
	fakeDeviceList(t, shutdownClone)

	attempts := 0
	w := newTestWatcher(nil, nil)
	w.preslim = func(Device, Profile) (int, error) {
		attempts++
		if attempts == 1 {
			return 0, errors.New("read-only store")
		}
		return 0, nil
	}
	for i := 0; i < 3; i++ {
		w.scan(context.Background())
	}
	if attempts != 2 {
		t.Fatalf("seed attempted %d times, want 2 (one failure, one retry)", attempts)
	}
}

// TestPreslimDeviceAddsOnlyDisables verifies the store gains the profile's
// disables and nothing else: an excepted service someone disabled stays
// disabled, the runtime's own entries survive, and a second pass is a no-op.
func TestPreslimDeviceAddsOnlyDisables(t *testing.T) {
	root := useTempStoreRoot(t)
	p, err := BuildProfile("", "store,icloud", "")
	if err != nil {
		t.Fatal(err)
	}
	var excepted string
	for _, c := range Categories {
		if c.ID == "store" {
			excepted = c.Labels[0]
		}
	}
	if err := writeDisabledStore("AAAA", []string{excepted}, []string{"com.example.runtime-own"}); err != nil {
		t.Fatal(err)
	}
	d := Device{UDID: "AAAA", State: "Shutdown", Platform: "iOS", OSVersion: "26.5"}

	n, err := preslimDevice(d, p)
	if err != nil {
		t.Fatalf("preslimDevice() error = %v", err)
	}
	desired := p.DesiredForDevice(d)
	if n != len(desired) {
		t.Fatalf("preslimDevice() added %d, want %d", n, len(desired))
	}
	entries, err := readStoreEntries("AAAA")
	if err != nil {
		t.Fatal(err)
	}
	for label := range desired {
		if !entries[label] {
			t.Errorf("%s not disabled in the store", label)
		}
	}
	if !entries[excepted] {
		t.Errorf("excepted %s was re-enabled; only `simslim off` may do that", excepted)
	}
	if off, ok := entries["com.example.runtime-own"]; !ok || off {
		t.Errorf("runtime's own enable entry = %v, %v; want kept as enabled", off, ok)
	}
	if n, err := preslimDevice(d, p); err != nil || n != 0 {
		t.Fatalf("second preslimDevice() = %d, %v; want 0, nil", n, err)
	}
	if _, err := os.Stat(filepath.Join(root, "com.apple.CoreSimulator.SimDevice.AAAA", "disabled.plist")); err != nil {
		t.Fatalf("store not at the launchd_sim path: %v", err)
	}
}

// TestPreslimDeviceLeavesOtherDevicesAlone verifies a booted device and a
// runtime that cannot persist overrides get no store.
func TestPreslimDeviceLeavesOtherDevicesAlone(t *testing.T) {
	useTempStoreRoot(t)
	for _, d := range []Device{
		{UDID: "BOOTED", State: "Booted", OSVersion: "26.5"},
		{UDID: "OLD", State: "Shutdown", OSVersion: "18.3"},
	} {
		if n, err := preslimDevice(d, Profile{}); err != nil || n != 0 {
			t.Fatalf("preslimDevice(%s) = %d, %v; want 0, nil", d.UDID, n, err)
		}
		if _, err := os.Stat(disabledStorePath(d.UDID)); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("store written for %s: %v", d.UDID, err)
		}
	}
}

// TestPollDeviceDirsReportsNewDevice verifies a device created after the poll
// starts is reported with its set, and the devices already there are not.
func TestPollDeviceDirsReportsNewDevice(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "OLD"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	created := make(chan deviceDir, 4)
	done := make(chan struct{})
	go func() {
		pollDeviceDirs(ctx, map[string]string{dir: "default", filepath.Join(dir, "missing"): "testing"}, time.Millisecond, func(d deviceDir) { created <- d })
		close(done)
	}()

	select {
	case d := <-created:
		t.Fatalf("an existing device was reported: %v", d)
	case <-time.After(20 * time.Millisecond):
	}
	if err := os.Mkdir(filepath.Join(dir, "NEW"), 0o755); err != nil {
		t.Fatal(err)
	}
	select {
	case d := <-created:
		if want := (deviceDir{path: filepath.Join(dir, "NEW"), set: "default"}); d != want {
			t.Fatalf("reported %v, want %v", d, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("a new device was not reported")
	}
	cancel()
	<-done
}

const newDevicePlist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>UDID</key>
	<string>CCCC</string>
	<key>deviceType</key>
	<string>com.apple.CoreSimulator.SimDeviceType.iPhone-17</string>
	<key>isDeleted</key>
	<false/>
	<key>name</key>
	<string>v4-1-a</string>
	<key>runtime</key>
	<string>com.apple.CoreSimulator.SimRuntime.iOS-26-5</string>
	<key>state</key>
	<integer>1</integer>
</dict>
</plist>
`

// TestSeedNewReadsDevicePlist verifies a new device is slimmed from its own
// device.plist, without a simctl listing, once the file appears.
func TestSeedNewReadsDevicePlist(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "CCCC")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	var seeds []Device
	w := newTestWatcher(nil, nil)
	w.preslim = func(d Device, _ Profile) (int, error) {
		seeds = append(seeds, d)
		return 0, nil
	}
	go func() {
		time.Sleep(30 * time.Millisecond) // simctl create writes device.plist after the directory
		os.WriteFile(filepath.Join(dir, "device.plist"), []byte(newDevicePlist), 0o644)
	}()
	w.seedNew(context.Background(), deviceDir{path: dir, set: "default"})

	want := Device{UDID: "CCCC", State: "Shutdown", Platform: "iOS", OSVersion: "26.5", Set: "default", DataPath: filepath.Join(dir, "data"), RuntimeID: "com.apple.CoreSimulator.SimRuntime.iOS-26-5"}
	if len(seeds) != 1 || seeds[0] != want {
		t.Fatalf("seeded %+v, want [%+v]", seeds, want)
	}
}
