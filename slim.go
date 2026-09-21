package simslim

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// Reporter receives human-readable progress lines. A nil Reporter is a no-op,
// so non-interactive callers can ignore progress entirely.
type Reporter func(string)

func (r Reporter) report(msg string) {
	if r != nil {
		r(msg)
	}
}

// ensure brings the device to exactly the desired disabled state and boots it.
// The disabled overrides persist in the device's launchd DB, so once set a slim
// device comes up slim in a single boot; a reboot only happens when the state
// actually changes. A non-empty profile is rejected before boot on runtimes
// without persistent overrides. On a runtime that persists them the device
// takes the far cheaper ensureOffline route, whatever state it starts in. Each
// slow phase reports progress so the caller can show the user that a
// multi-minute reconfigure is still working.
func ensure(ctx context.Context, set, udid string, desired map[string]bool, report Reporter) (changed bool, err error) {
	d, err := FindDevice(ctx, udid, set)
	if err != nil {
		return false, err
	}
	persistent := PersistentOverridesSupported(d.OSVersion)
	if len(desired) > 0 && !persistent {
		return false, fmt.Errorf("iOS %s runtime cannot persist launchd disable overrides across reboot; simslim requires iOS 18.5 or newer, or `simslim on --no-reboot` to slim the current boot session only", d.OSVersion)
	}
	// A shutdown device can be reconfigured by writing the overrides launchd_sim
	// reads when it starts, which skips both the per-label launchctl spawns and
	// the reboot that would apply them: minutes become seconds.
	booted := d.State == "Booted"
	if booted && persistent {
		// `simctl list` says Booted from the moment the boot starts, so wait
		// for launchd to be up before asking it anything; on a device that is
		// really booted this costs a fraction of a second.
		if err := BootAndWait(ctx, set, udid); err != nil {
			return false, err
		}
		// An override only takes effect at the next boot, so a booted device
		// already owes us a shutdown and a boot. Spending them up front, before
		// touching launchd, makes it a shutdown device and lets the store
		// replace every launchctl spawn for the same two state changes.
		live, err := readDisabled(ctx, set, udid)
		if err != nil {
			return false, err
		}
		if toDisable, toEnable := delta(live, desired, managedSet()); len(toDisable) == 0 && len(toEnable) == 0 {
			return false, nil
		}
		report.report("Shutting the simulator down to reconfigure it offline...")
		if err := Shutdown(ctx, set, udid); err != nil {
			return false, fmt.Errorf("shutdown before reconfigure: %w", err)
		}
		if err := WaitShutdown(ctx, set, udid, ShutdownTimeout); err != nil {
			return false, err
		}
		d.State = "Shutdown"
	}
	if d.State == "Shutdown" && persistent {
		changed, err := ensureOffline(ctx, set, udid, desired, report)
		if !errors.Is(err, errOfflineIneffective) {
			// A device that started booted only gets here with a real delta.
			return changed || booted, err
		}
		report.report("Could not apply the changes while the simulator was off; reconfiguring it while booted instead...")
	}
	report.report("Booting the simulator (a first boot can take up to a minute)...")
	if err := BootAndWait(ctx, set, udid); err != nil {
		return false, err
	}
	current, err := readDisabled(ctx, set, udid)
	if err != nil {
		return false, err
	}
	toDisable, toEnable := delta(current, desired, managedSet())
	if len(toDisable) == 0 && len(toEnable) == 0 {
		return false, nil
	}
	if len(toDisable) > 0 {
		report.report(fmt.Sprintf("Disabling %d background services...", len(toDisable)))
	}
	if len(toEnable) > 0 {
		report.report(fmt.Sprintf("Re-enabling %d background services...", len(toEnable)))
	}
	if err := applyDelta(ctx, set, udid, toDisable, toEnable, "disable", report); err != nil {
		return true, err
	}
	report.report("Rebooting the simulator to apply the changes...")
	if err := Shutdown(ctx, set, udid); err != nil {
		return true, fmt.Errorf("shutdown before reboot: %w", err)
	}
	if err := WaitShutdown(ctx, set, udid, ShutdownTimeout); err != nil {
		return true, err
	}
	if err := BootAndWait(ctx, set, udid); err != nil {
		return true, err
	}
	after, err := readDisabled(ctx, set, udid)
	if err != nil {
		return true, err
	}
	if lost := countLost(after, desired, managedSet()); lost > 0 {
		return true, fmt.Errorf("the disable overrides did not survive the reboot (%d of %d changes lost)", lost, len(toDisable)+len(toEnable))
	}
	return true, nil
}

// ensureOffline reaches the desired state on a shutdown device by writing its
// launchd overrides directly, then boots it once — already slim. That replaces a
// boot, one launchctl spawn per label, and a reboot with a single boot. The
// state is read back from the booted device rather than trusted: the store is a
// private CoreSimulator detail, so anything that stops it from working returns
// errOfflineIneffective and the caller takes the supported path instead.
func ensureOffline(ctx context.Context, set, udid string, desired map[string]bool, report Reporter) (changed bool, err error) {
	current, err := readDisabledStore(udid)
	if err != nil {
		return false, fmt.Errorf("%w: %v", errOfflineIneffective, err)
	}
	toDisable, toEnable := delta(current, desired, managedSet())
	changed = len(toDisable) > 0 || len(toEnable) > 0
	if changed {
		report.report(fmt.Sprintf("Reconfiguring %d background services while the simulator is off...", len(toDisable)+len(toEnable)))
		if err := writeDisabledStore(udid, toDisable, toEnable); err != nil {
			return false, fmt.Errorf("%w: %v", errOfflineIneffective, err)
		}
	}
	report.report("Booting the simulator (a first boot can take up to a minute)...")
	if err := BootAndWait(ctx, set, udid); err != nil {
		return changed, err
	}
	after, err := readDisabled(ctx, set, udid)
	if err != nil {
		return changed, err
	}
	if lost := countLost(after, desired, managedSet()); lost > 0 {
		return changed, fmt.Errorf("%d of %d offline overrides were not honoured at boot: %w", lost, len(toDisable)+len(toEnable), errOfflineIneffective)
	}
	return changed, nil
}

// errOfflineIneffective means the store was written but the booted device did
// not come up in the desired state. The store is an undocumented CoreSimulator
// detail, so a runtime is always free to ignore it; callers treat this as "take
// the supported path instead", never as a failure.
var errOfflineIneffective = errors.New("offline launchd overrides not honoured")

// countLost reports how many of the desired managed transitions are not
// reflected in the state read back after the reboot.
func countLost(after, desired, managed map[string]bool) int {
	toDisable, toEnable := delta(after, desired, managed)
	return len(toDisable) + len(toEnable)
}

// PersistentOverridesSupported reports whether the runtime keeps launchd
// disable overrides across reboot. iOS 17.x and 18.3 hold them in memory only
// and come back stock; iOS 18.5 and newer are verified to persist them.
func PersistentOverridesSupported(version string) bool {
	parts := strings.SplitN(version, ".", 3)
	if len(parts) < 2 {
		return false
	}
	major, majorErr := strconv.Atoi(parts[0])
	minor, minorErr := strconv.Atoi(parts[1])
	return majorErr == nil && minorErr == nil && (major > 18 || major == 18 && minor >= 5)
}

// enableSlim disables the profile's daemons and boots the device slim.
func EnableSlim(ctx context.Context, set, udid string, p Profile, report Reporter) (bool, error) {
	return ensure(ctx, set, udid, p.Desired(), report)
}

// EnableSlimNoReboot slims the running boot session without a reboot: each
// daemon the profile disables is booted out of launchd, and the disable
// override keeps launchd from respawning it. It works on every runtime, but on
// runtimes without persistent overrides the simulator comes back stock at its
// next boot. Live slimming only moves toward more-disabled: managed labels
// disabled beyond the profile are left alone, because a live re-enable would
// have to bootstrap each daemon again; `off` restores them with a reboot.
func EnableSlimNoReboot(ctx context.Context, set, udid string, p Profile, report Reporter) (changed bool, err error) {
	desired := p.Desired()
	report.report("Booting the simulator (a first boot can take up to a minute)...")
	if err := BootAndWait(ctx, set, udid); err != nil {
		return false, err
	}
	current, err := readDisabled(ctx, set, udid)
	if err != nil {
		return false, err
	}
	managed := managedSet()
	toDisable, extra := delta(current, desired, managed)
	if len(extra) > 0 {
		report.report(fmt.Sprintf("Leaving %d services disabled beyond this profile; only `simslim off` re-enables them.", len(extra)))
	}
	// Boot out every profiled label, not just those without an override: an
	// override says nothing about whether the job is still loaded (an earlier
	// run may have disabled it and then failed to boot it out). A bootout of
	// an already-missing job is a cheap no-op, so this keeps the command idempotent.
	changed = len(toDisable) > 0
	labels := make([]string, 0, len(desired))
	for l := range desired {
		if managed[l] {
			labels = append(labels, l)
		}
	}
	sort.Strings(labels)
	report.report(fmt.Sprintf("Stopping %d background services for this boot session...", len(labels)))
	if err := applyDelta(ctx, set, udid, labels, nil, liveDisable, report); err != nil {
		return changed, err
	}
	after, err := readDisabled(ctx, set, udid)
	if err != nil {
		return changed, err
	}
	if missing, _ := delta(after, desired, managed); len(missing) > 0 {
		return changed, fmt.Errorf("%d of %d disable overrides did not take", len(missing), len(labels))
	}
	return changed, nil
}

// disableSlim re-enables every managed daemon, returning the device to stock.
func DisableSlim(ctx context.Context, set, udid string, report Reporter) (bool, error) {
	return ensure(ctx, set, udid, map[string]bool{}, report)
}

// Status describes how slim a device currently is.
type Status struct {
	ManagedDisabled int  `json:"managedDisabled"` // managed labels currently disabled
	ManagedTotal    int  `json:"managedTotal"`    // size of the managed universe
	Booted          bool `json:"booted"`
	Persistent      bool `json:"persistent"` // the runtime keeps disabled state across reboot
}

// status reports how slim a device is and returns the labels it currently has
// disabled (nil when the device is not booted).
func ReadStatus(ctx context.Context, udid string) (Status, map[string]bool, error) {
	d, err := FindDevice(ctx, udid, "")
	if err != nil {
		return Status{}, nil, err
	}
	return ReadStatusForDevice(ctx, d)
}

func ReadStatusForDevice(ctx context.Context, d Device) (Status, map[string]bool, error) {
	managed := SlimmableSet()
	st := Status{ManagedTotal: len(managed), Booted: d.State == "Booted", Persistent: PersistentOverridesSupported(d.OSVersion)}
	if !st.Booted {
		return st, nil, fmt.Errorf("simulator must be booted to read its state (it is %s)", d.State)
	}
	disabled, err := readDisabled(ctx, d.Set, d.UDID)
	if err != nil {
		return st, nil, err
	}
	for l := range disabled {
		if managed[l] {
			st.ManagedDisabled++
		}
	}
	return st, disabled, nil
}

// droppedCategories groups the disabled managed daemons by category, in category
// order, omitting categories with nothing disabled.
func DroppedCategories(disabled map[string]bool) []DroppedCategory {
	var out []DroppedCategory
	for _, c := range Categories {
		var labels []string
		for _, l := range c.Labels {
			if disabled[l] {
				labels = append(labels, l)
			}
		}
		if len(labels) == 0 {
			continue
		}
		sort.Strings(labels)
		out = append(out, DroppedCategory{ID: c.ID, Name: c.Name, Downside: c.Downside, Labels: labels})
	}
	return out
}
