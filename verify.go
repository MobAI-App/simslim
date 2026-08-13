package simslim

import (
	"context"
	"fmt"
	"sort"
)

// VerifyResult reports how a booted simulator's launchd disable overrides
// compare to a profile's desired set. Only managed labels are considered.
type VerifyResult struct {
	UDID    string   `json:"udid"`
	OK      bool     `json:"ok"`
	Missing []string `json:"missing,omitempty"` // profile wants these disabled; they are enabled
	Extra   []string `json:"extra,omitempty"`   // managed labels disabled beyond the profile
}

// VerifyProfile checks, without mutating anything, that a booted simulator's
// disable overrides match the profile exactly. The overrides are per-simulator
// state that is easy to lose silently when a device is erased or recreated, so
// VerifyProfile detects the drift and callers can re-run `on` (which is
// idempotent) to repair it. SimSlim-created clones preserve this state.
func VerifyProfile(ctx context.Context, udid string, p Profile) (VerifyResult, error) {
	d, err := FindDevice(ctx, udid, "")
	if err != nil {
		return VerifyResult{}, err
	}
	if d.State != "Booted" {
		return VerifyResult{}, fmt.Errorf("simulator must be booted to read its state (it is %s)", d.State)
	}
	disabled, err := readDisabled(ctx, d.Set, d.UDID)
	if err != nil {
		return VerifyResult{}, err
	}
	r := compareDisabled(disabled, p.Desired(), managedSet())
	r.UDID = udid
	return r, nil
}

// compareDisabled diffs the currently disabled labels against the desired set,
// restricted to the managed universe (unmanaged labels are never simslim's
// business and never count as drift).
func compareDisabled(disabled, desired, managed map[string]bool) VerifyResult {
	var r VerifyResult
	for l := range desired {
		if !disabled[l] {
			r.Missing = append(r.Missing, l)
		}
	}
	for l := range disabled {
		if managed[l] && !desired[l] {
			r.Extra = append(r.Extra, l)
		}
	}
	sort.Strings(r.Missing)
	sort.Strings(r.Extra)
	r.OK = len(r.Missing) == 0 && len(r.Extra) == 0
	return r
}
