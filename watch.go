package simslim

import (
	"context"
	"fmt"
	"sort"
	"time"
)

// DefaultWatchInterval is how often Watch rescans the device sets.
const DefaultWatchInterval = 3 * time.Second

// slimStrategy is the per-device slimming applied by Watch. It is a field so
// tests can substitute a fake for EnableSlimNoReboot.
type slimStrategy func(ctx context.Context, set, udid string, p Profile, report Reporter) (bool, error)

// Watch slims each simulator no-reboot as it boots, then leaves it alone.
// xcodebuild creates parallel-testing clones stock and deletes them per run, so
// no device exists to pre-slim: the only hook is to catch each clone once it
// boots. A clone slimmed a few seconds into a multi-minute run frees its
// background daemons for the rest of the run. Watch runs until ctx is cancelled
// (Ctrl-C), scanning the default, testing, and any --set device sets. It slims
// each device in its own goroutine so one slow reconfigure does not delay
// catching the next clone.
func Watch(ctx context.Context, p Profile, interval time.Duration, report Reporter) error {
	return watch(ctx, p, interval, report, EnableSlimNoReboot)
}

func watch(ctx context.Context, p Profile, interval time.Duration, report Reporter, slim slimStrategy) error {
	if interval <= 0 {
		interval = DefaultWatchInterval
	}
	seen := map[string]bool{} // UDIDs already slimmed or in flight; scan loop is single-threaded
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		scanAndSlim(ctx, p, report, slim, seen)
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

func scanAndSlim(ctx context.Context, p Profile, report Reporter, slim slimStrategy, seen map[string]bool) {
	devices, err := ListDevices(ctx)
	if err != nil {
		report.report(fmt.Sprintf("watch: list devices: %v", err))
		return
	}
	sort.Slice(devices, func(i, j int) bool { return devices[i].UDID < devices[j].UDID })
	for _, d := range devices {
		if d.State != "Booted" || seen[d.UDID] {
			continue
		}
		seen[d.UDID] = true
		go func(d Device) {
			report.report(fmt.Sprintf("watch: slimming %s (set %s)", d.UDID, d.Set))
			if _, err := slim(ctx, d.Set, d.UDID, p, nil); err != nil {
				report.report(fmt.Sprintf("watch: %s: %v", d.UDID, err))
				return
			}
			report.report(fmt.Sprintf("watch: slimmed %s", d.UDID))
		}(d)
	}
}
