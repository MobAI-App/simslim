package simslim

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// DefaultWatchInterval is how often Watch rescans the device sets.
const DefaultWatchInterval = 3 * time.Second

// deviceDirPollInterval is how often Watch lists the device-set directories for
// a newly created simulator. Listing a directory is one cheap syscall, while a
// `simctl list` takes seconds on a loaded host, so only the listing can catch a
// device between `simctl create` and an immediate boot.
const deviceDirPollInterval = 50 * time.Millisecond

// newDevicePlistWait bounds how long Watch waits for a new device directory's
// device.plist, which `simctl create` writes just after the directory.
const newDevicePlistWait = 2 * time.Second

// slimStrategy is the per-device slimming applied by Watch. It is a field so
// tests can substitute a fake for EnableSlimNoReboot.
type slimStrategy func(ctx context.Context, set, udid string, p Profile, report Reporter) (bool, error)

// preslimStrategy seeds a shut-down device before it boots. It is a field so
// tests can substitute a fake for preslimDevice.
type preslimStrategy func(d Device, p Profile) (int, error)

// Watch slims every simulator so that none starts the profile's daemons, then
// leaves it alone until it boots again.
// A shut-down simulator on a runtime that persists overrides is slimmed before
// it boots: Watch writes the profile's disable overrides into its launchd store,
// so its next boot, its very first included, starts none of those daemons. New
// devices are caught within deviceDirPollInterval of their creation, ahead of a
// tool that creates and boots at once. Every simulator is still slimmed no-reboot
// as it boots: that reads the device back, and it is the only hook for a device
// that booted before its store was seeded, on an older runtime, or as an
// xcodebuild parallel-testing clone (cloned stock, since overrides do not
// survive `simctl clone`, and booted at once). Watch runs until ctx is cancelled
// (Ctrl-C), scanning the default, testing, and any --set device sets. It slims
// each booted device in its own goroutine so one slow reconfigure does not delay
// catching the next clone, and returns once those goroutines are done.
func Watch(ctx context.Context, p Profile, interval time.Duration, report Reporter) error {
	return watch(ctx, p, interval, report, EnableSlimNoReboot)
}

func watch(ctx context.Context, p Profile, interval time.Duration, report Reporter, slim slimStrategy) error {
	if interval <= 0 {
		interval = DefaultWatchInterval
	}
	w := &watcher{p: p, report: report, slim: slim, preslim: preslimDevice, seen: map[string]bool{}, seeded: map[string]bool{}}
	// The CLI exits right after this returns, but an importer keeps running, so
	// no slim may outlive the call. A cancelled ctx aborts an in-flight slim
	// inside its next simctl call, which keeps the wait short.
	defer w.wg.Wait()
	created := make(chan struct{}, 1)
	w.wg.Add(1)
	go func() {
		defer w.wg.Done()
		pollDeviceDirs(ctx, deviceSetDirs(), deviceDirPollInterval, func(dir deviceDir) {
			w.seedNew(ctx, dir)
			select {
			case created <- struct{}{}:
			default: // a scan is already due
			}
		})
	}()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		w.scan(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		case <-created:
		}
	}
}

// preslimDevice writes the profile's missing disable overrides into a shut-down
// device's launchd store and reports how many it added. Like the no-reboot slim
// Watch applies after boot, it only ever adds disables: a service someone
// disabled beyond the profile stays disabled, and nothing is re-enabled. A
// device that is not shut down, or whose runtime does not persist overrides,
// is left alone; the after-boot slim covers it.
func preslimDevice(d Device, p Profile) (int, error) {
	if d.State != "Shutdown" || !d.SupportsPersistentOverrides() {
		return 0, nil
	}
	current, err := readDisabledStore(d.UDID)
	if err != nil {
		return 0, err
	}
	toDisable, _ := delta(current, p.DesiredForDevice(d), managedSet())
	if len(toDisable) == 0 {
		return 0, nil
	}
	if err := writeDisabledStore(d.UDID, toDisable, nil); err != nil {
		return 0, err
	}
	return len(toDisable), nil
}

// deviceDir is one device's directory, named by its UDID, in a scanned set.
type deviceDir struct {
	path string
	set  string
}

// deviceSetDirs maps each scanned set's device directory to the set's name:
// CoreSimulator's default set, the parallel-testing set, and any --set path.
func deviceSetDirs() map[string]string {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil
	}
	dirs := map[string]string{}
	for _, set := range knownDeviceSets() {
		switch set.token {
		case "":
			dirs[filepath.Join(home, "Library", "Developer", "CoreSimulator", "Devices")] = set.name
		case "testing":
			dirs[filepath.Join(home, "Library", "Developer", "XCTestDevices")] = set.name
		default:
			dirs[set.token] = set.name
		}
	}
	return dirs
}

// pollDeviceDirs calls created for each directory that appears in one of
// setDirs, until ctx is cancelled. A set directory that does not exist yet is
// simply empty.
func pollDeviceDirs(ctx context.Context, setDirs map[string]string, interval time.Duration, created func(deviceDir)) {
	known := map[string]bool{}
	list := func() (fresh []deviceDir) {
		for dir, set := range setDirs {
			entries, _ := os.ReadDir(dir)
			for _, e := range entries {
				path := filepath.Join(dir, e.Name())
				if e.IsDir() && !known[path] {
					known[path] = true
					fresh = append(fresh, deviceDir{path: path, set: set})
				}
			}
		}
		return fresh
	}
	list() // devices that already exist are the first scan's business
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		for _, dir := range list() {
			created(dir)
		}
	}
}

// readDevicePlist reads the device CoreSimulator describes in a device
// directory's device.plist: its UDID, runtime and state (1 is Shutdown).
func readDevicePlist(dir deviceDir) (Device, error) {
	f, err := os.Open(filepath.Join(dir.path, "device.plist"))
	if err != nil {
		return Device{}, err
	}
	defer f.Close()
	values := map[string]string{}
	decoder := xml.NewDecoder(f)
	key := ""
	for {
		token, err := decoder.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return Device{}, fmt.Errorf("parse device.plist: %w", err)
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		var text string
		switch start.Name.Local {
		case "key":
			if err := decoder.DecodeElement(&key, &start); err != nil {
				return Device{}, fmt.Errorf("parse device.plist: %w", err)
			}
		case "string", "integer":
			if err := decoder.DecodeElement(&text, &start); err != nil {
				return Device{}, fmt.Errorf("parse device.plist: %w", err)
			}
			values[key] = text
		}
	}
	platform, version := parseRuntime(values["runtime"])
	if values["UDID"] == "" || platform == "" {
		return Device{}, fmt.Errorf("device.plist names no UDID or supported runtime")
	}
	state := "Booted"
	if values["state"] == "1" {
		state = "Shutdown"
	}
	return Device{UDID: values["UDID"], State: state, Platform: platform, OSVersion: version, Set: dir.set, DataPath: filepath.Join(dir.path, "data"), RuntimeID: values["runtime"]}, nil
}

// seedNew slims a just-created device before its first boot, straight from its
// directory and without a `simctl list`, which on a loaded host would still be
// running when a script that boots right after creating has started launchd_sim.
func (w *watcher) seedNew(ctx context.Context, dir deviceDir) {
	deadline := time.Now().Add(newDevicePlistWait)
	d, err := readDevicePlist(dir)
	for err != nil && time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return
		case <-time.After(10 * time.Millisecond):
		}
		d, err = readDevicePlist(dir)
	}
	if err != nil {
		return // not a device, or not one simslim slims; the scan decides
	}
	w.seed(d)
}

// watcher holds the UDIDs already slimmed or in flight, and in seeded the
// shut-down UDIDs whose store already holds the profile. The scan loop, the
// slim goroutines and the directory poll all touch them, so mu guards both.
type watcher struct {
	p       Profile
	report  Reporter
	slim    slimStrategy
	preslim preslimStrategy
	wg      sync.WaitGroup
	mu      sync.Mutex
	seen    map[string]bool
	seeded  map[string]bool
}

func (w *watcher) scan(ctx context.Context) {
	devices, err := ListDevices(ctx)
	if err != nil {
		w.report.report(fmt.Sprintf("watch: list devices: %v", err))
		return
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].UDID < devices[j].UDID })
	for _, d := range devices {
		if d.State != "Booted" {
			// On iOS below 18.5 the no-reboot slim dies with the boot session,
			// so a device that shut down comes back stock and needs slimming
			// again. Re-slimming an already-slim device is a cheap no-op.
			w.forget(d.UDID)
			w.seed(d)
			continue
		}
		// A booted device may change its own store (and `simslim off` may
		// clear it), so check it again the next time it is shut down.
		w.mu.Lock()
		delete(w.seeded, d.UDID)
		w.mu.Unlock()
		if !w.claim(d.UDID) {
			continue
		}
		w.wg.Add(1)
		go func(d Device) {
			defer w.wg.Done()
			w.report.report(fmt.Sprintf("watch: slimming %s (set %s)", d.UDID, d.Set))
			if _, err := w.slim(ctx, d.Set, d.UDID, w.p, prefixed(w.report, d.UDID)); err != nil {
				w.report.report(fmt.Sprintf("watch: %s: %v", d.UDID, err))
				// A transient launchctl failure would otherwise leave this clone
				// stock for the whole test run. The next scan retries it, and a
				// torn-down clone drops out of simctl list, so this does not loop.
				w.forget(d.UDID)
				return
			}
			w.report.report(fmt.Sprintf("watch: slimmed %s", d.UDID))
		}(d)
	}
}

// seed slims a shut-down device ahead of its next boot, once per shutdown. A
// failure is retried on the next scan, and the after-boot slim still covers
// the device if it boots first.
func (w *watcher) seed(d Device) {
	if w.preslim == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock() // serializes the store writes of seedNew and scan
	if w.seeded[d.UDID] {
		return
	}
	n, err := w.preslim(d, w.p)
	if err != nil {
		w.report.report(fmt.Sprintf("watch: %s: slim before boot: %v", d.UDID, err))
		return
	}
	w.seeded[d.UDID] = true
	if n == 0 {
		return
	}
	// launchd_sim reads the store once, when it starts: a seed that lands after
	// the boot began only counts from the next boot.
	if now, err := readDevicePlist(deviceDir{path: filepath.Dir(d.DataPath), set: d.Set}); d.DataPath != "" && err == nil && now.State != "Shutdown" {
		w.report.report(fmt.Sprintf("watch: %s booted before its slim (%d services) landed; slimming it as it boots", d.UDID, n))
		return
	}
	w.report.report(fmt.Sprintf("watch: slimmed %s before boot (%d services disabled, set %s)", d.UDID, n, d.Set))
}

// claim reserves a UDID for this scan, reporting false when it is already
// slimmed or in flight.
func (w *watcher) claim(udid string) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.seen[udid] {
		return false
	}
	w.seen[udid] = true
	return true
}

func (w *watcher) forget(udid string) {
	w.mu.Lock()
	delete(w.seen, udid)
	w.mu.Unlock()
}

// prefixed tags a device's own progress lines with its UDID, so the interleaved
// output of concurrent slims stays attributable.
func prefixed(report Reporter, udid string) Reporter {
	return func(msg string) { report.report(fmt.Sprintf("watch: %s: %s", udid, msg)) }
}
