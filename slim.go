package main

import (
	"context"
	"fmt"
)

// ensure brings the device to exactly the desired disabled state and boots it.
// The disabled overrides persist in the device's launchd DB, so once set a slim
// device comes up slim in a single boot; a reboot only happens when the state
// actually changes. A running device is required to read/mutate launchctl, so
// the device is booted first regardless.
func ensure(ctx context.Context, udid string, desired map[string]bool) (changed bool, err error) {
	if err := bootAndWait(ctx, udid); err != nil {
		return false, err
	}
	current, err := readDisabled(ctx, udid)
	if err != nil {
		return false, err
	}
	toDisable, toEnable := delta(current, desired, managedSet())
	if len(toDisable) == 0 && len(toEnable) == 0 {
		return false, nil
	}
	if err := applyDelta(ctx, udid, toDisable, toEnable); err != nil {
		return true, err
	}
	if err := shutdown(ctx, udid); err != nil {
		return true, fmt.Errorf("shutdown before reboot: %w", err)
	}
	if err := waitShutdown(ctx, udid, shutdownTimeout); err != nil {
		return true, err
	}
	return true, bootAndWait(ctx, udid)
}

// enableSlim disables the profile's daemons and boots the device slim.
func enableSlim(ctx context.Context, udid string, p Profile) (bool, error) {
	return ensure(ctx, udid, p.desired())
}

// disableSlim re-enables every managed daemon, returning the device to stock.
func disableSlim(ctx context.Context, udid string) (bool, error) {
	return ensure(ctx, udid, map[string]bool{})
}

// Status describes how slim a device currently is.
type Status struct {
	ManagedDisabled int  `json:"managedDisabled"` // managed labels currently disabled
	ManagedTotal    int  `json:"managedTotal"`    // size of the managed universe
	Booted          bool `json:"booted"`
}

func status(ctx context.Context, udid string) (Status, error) {
	d, err := findDevice(ctx, udid)
	if err != nil {
		return Status{}, err
	}
	return statusForDevice(ctx, d)
}

func statusForDevice(ctx context.Context, d Device) (Status, error) {
	managed := managedSet()
	st := Status{ManagedTotal: len(managed), Booted: d.State == "Booted"}
	if !st.Booted {
		return st, fmt.Errorf("simulator must be booted to read its state (it is %s)", d.State)
	}
	disabled, err := readDisabled(ctx, d.UDID)
	if err != nil {
		return st, err
	}
	for l := range disabled {
		if managed[l] {
			st.ManagedDisabled++
		}
	}
	return st, nil
}
