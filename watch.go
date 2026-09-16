package simslim

import (
	"context"
	"fmt"
	"sort"
	"sync"
	"time"
)

// DefaultWatchInterval is how often Watch rescans the device sets.
const DefaultWatchInterval = 3 * time.Second

// slimStrategy is the per-device slimming applied by Watch. It is a field so
// tests can substitute a fake for EnableSlimNoReboot.
type slimStrategy func(ctx context.Context, set, udid string, p Profile, report Reporter) (bool, error)

// Watch slims each simulator no-reboot as it boots, then leaves it alone until
// it boots again.
// xcodebuild creates parallel-testing clones stock and deletes them per run, so
// no device exists to pre-slim: the only hook is to catch each clone once it
// boots. A clone slimmed a few seconds into a multi-minute run frees its
// background daemons for the rest of the run. Watch runs until ctx is cancelled
// (Ctrl-C), scanning the default, testing, and any --set device sets. It slims
// each device in its own goroutine so one slow reconfigure does not delay
// catching the next clone, and returns once those goroutines are done.
func Watch(ctx context.Context, p Profile, interval time.Duration, report Reporter) error {
	return watch(ctx, p, interval, report, EnableSlimNoReboot)
}

func watch(ctx context.Context, p Profile, interval time.Duration, report Reporter, slim slimStrategy) error {
	if interval <= 0 {
		interval = DefaultWatchInterval
	}
	w := &watcher{p: p, report: report, slim: slim, seen: map[string]bool{}}
	// The CLI exits right after this returns, but an importer keeps running, so
	// no slim may outlive the call. A cancelled ctx aborts an in-flight slim
	// inside its next simctl call, which keeps the wait short.
	defer w.wg.Wait()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		w.scan(ctx)
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

// watcher holds the UDIDs already slimmed or in flight. The scan loop and the
// slim goroutines both mutate seen, so mu guards every access to it.
type watcher struct {
	p      Profile
	report Reporter
	slim   slimStrategy
	wg     sync.WaitGroup
	mu     sync.Mutex
	seen   map[string]bool
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
			continue
		}
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
