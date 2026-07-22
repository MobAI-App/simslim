package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Device is a simulator as reported by `simctl list`.
type Device struct {
	UDID      string `json:"udid"`
	Name      string `json:"name"`
	State     string `json:"state"` // "Booted" or "Shutdown"
	OSVersion string `json:"osVersion"`
	Set       string `json:"set"`
	DataPath  string `json:"-"`
}

type deviceSetInfo struct {
	token string // "" for the default set; otherwise passed to `simctl --set`
	name  string
}

// extraDeviceSets are sets named explicitly with --set
var extraDeviceSets []deviceSetInfo

func knownDeviceSets() []deviceSetInfo {
	sets := []deviceSetInfo{
		{token: "", name: "default"},
		{token: "testing", name: "testing"},
	}
	return append(sets, extraDeviceSets...)
}

// registerDeviceSet adds a --set value to the scanned sets
// ignoring any that duplicate an already-known token.
func registerDeviceSet(value string) {
	for _, set := range knownDeviceSets() {
		if set.token == value {
			return
		}
	}
	extraDeviceSets = append(extraDeviceSets, deviceSetInfo{token: value, name: value})
}

func deviceSetToken(name string) string {
	for _, set := range knownDeviceSets() {
		if set.name == name {
			return set.token
		}
	}
	return ""
}

// simctlArgs targets the named device set; deviceSetToken maps "default" to the
// empty --set token, "testing" and custom paths to themselves.
func simctlArgs(set string, sub ...string) []string {
	return simctlArgsForSet(deviceSetToken(set), sub...)
}

// The --set option must precede the subcommand.
func simctlArgsForSet(token string, sub ...string) []string {
	if token == "" {
		return append([]string{"simctl"}, sub...)
	}
	return append([]string{"simctl", "--set", token}, sub...)
}

func xcrun(ctx context.Context, args ...string) ([]byte, error) {
	out, err := exec.CommandContext(ctx, "xcrun", args...).CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("xcrun %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func listDevicesInSet(ctx context.Context, set deviceSetInfo) ([]Device, error) {
	out, err := exec.CommandContext(ctx, "xcrun", simctlArgsForSet(set.token, "list", "devices", "-j")...).Output()
	if err != nil {
		return nil, fmt.Errorf("simctl list: %w", err)
	}
	var parsed struct {
		Devices map[string][]struct {
			UDID        string `json:"udid"`
			Name        string `json:"name"`
			State       string `json:"state"`
			IsAvailable bool   `json:"isAvailable"`
			DataPath    string `json:"dataPath"`
		} `json:"devices"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, fmt.Errorf("parse simctl list: %w", err)
	}
	var devices []Device
	for runtime, ds := range parsed.Devices {
		if !strings.Contains(runtime, "iOS") {
			continue
		}
		for _, d := range ds {
			if !d.IsAvailable {
				continue
			}
			devices = append(devices, Device{UDID: d.UDID, Name: d.Name, State: d.State, OSVersion: osVersion(runtime), Set: set.name, DataPath: d.DataPath})
		}
	}
	return devices, nil
}

// The default set is mandatory; a secondary set that cannot be listed (e.g. it
// does not exist) is skipped rather than failing the whole listing.
func listDevices(ctx context.Context) ([]Device, error) {
	var devices []Device
	for _, set := range knownDeviceSets() {
		found, err := listDevicesInSet(ctx, set)
		if err != nil {
			if set.token == "" {
				return nil, err
			}
			continue
		}
		devices = append(devices, found...)
	}
	return devices, nil
}

// osVersion turns "com.apple.CoreSimulator.SimRuntime.iOS-26-5" into "26.5".
func osVersion(runtime string) string {
	i := strings.LastIndex(runtime, "iOS-")
	if i < 0 {
		return "?"
	}
	return strings.ReplaceAll(runtime[i+len("iOS-"):], "-", ".")
}

// findDevice locates a simulator by UDID. An empty set searches every known set.
// A non-empty set looks only there, so repeated lookups need not rescan.
func findDevice(ctx context.Context, udid, set string) (Device, error) {
	for _, s := range knownDeviceSets() {
		if set != "" && s.name != set {
			continue
		}
		found, err := listDevicesInSet(ctx, s)
		if err != nil {
			if s.token == "" {
				return Device{}, err
			}
			continue
		}
		for _, d := range found {
			if d.UDID == udid {
				return d, nil
			}
		}
	}
	return Device{}, fmt.Errorf("no simulator with udid %s", udid)
}

func normalizeSimulatorName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", fmt.Errorf("simulator name cannot be empty")
	}
	if utf8.RuneCountInString(name) > 128 {
		return "", fmt.Errorf("simulator name cannot exceed 128 characters")
	}
	for _, r := range name {
		if unicode.IsControl(r) {
			return "", fmt.Errorf("simulator name cannot contain control characters")
		}
	}
	return name, nil
}

func parseClonedUDID(output []byte) (string, error) {
	udid := strings.TrimSpace(string(output))
	if len(udid) != 36 {
		return "", fmt.Errorf("simctl clone returned an invalid UDID %q", udid)
	}
	for i, r := range udid {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if r != '-' {
				return "", fmt.Errorf("simctl clone returned an invalid UDID %q", udid)
			}
			continue
		}
		if !((r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')) {
			return "", fmt.Errorf("simctl clone returned an invalid UDID %q", udid)
		}
	}
	return udid, nil
}

// shutdownIfBooted resolves an exact device before any destructive command,
// preventing simctl aliases such as "all" from entering these code paths. It
// returns the device's set so the caller can target its own simctl call there.
func shutdownIfBooted(ctx context.Context, udid string) (set string, wasBooted bool, err error) {
	device, err := findDevice(ctx, udid, "")
	if err != nil {
		return "", false, err
	}
	if device.State != "Booted" {
		return device.Set, false, nil
	}
	if err := shutdown(ctx, device.Set, udid); err != nil {
		return device.Set, true, err
	}
	if err := waitShutdown(ctx, device.Set, udid, shutdownTimeout); err != nil {
		return device.Set, true, err
	}
	return device.Set, true, nil
}

// cloneDevice temporarily shuts down a booted source because CoreSimulator can
// only clone a stable device, then restores the source's original boot state.
func cloneDevice(ctx context.Context, udid, name string) (newUDID string, err error) {
	name, err = normalizeSimulatorName(name)
	if err != nil {
		return "", err
	}
	set, wasBooted, err := shutdownIfBooted(ctx, udid)
	if err != nil {
		return "", err
	}
	if wasBooted {
		defer func() {
			restoreCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), bootTimeout)
			defer cancel()
			if restoreErr := bootAndWait(restoreCtx, set, udid); restoreErr != nil {
				if err != nil {
					err = fmt.Errorf("%v; additionally could not restore the source boot state: %w", err, restoreErr)
				} else if newUDID != "" {
					err = fmt.Errorf("cloned simulator %s, but could not restore the source boot state: %w", newUDID, restoreErr)
				} else {
					err = fmt.Errorf("could not restore the source boot state: %w", restoreErr)
				}
			}
		}()
	}

	out, err := xcrun(ctx, simctlArgs(set, "clone", udid, name)...)
	if err != nil {
		return "", err
	}
	return parseClonedUDID(out)
}

func renameDevice(ctx context.Context, udid, name string) error {
	device, err := findDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	name, err = normalizeSimulatorName(name)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, simctlArgs(device.Set, "rename", udid, name)...)
	return err
}

func eraseDevice(ctx context.Context, udid string) error {
	set, _, err := shutdownIfBooted(ctx, udid)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, simctlArgs(set, "erase", udid)...)
	return err
}

func deleteDevice(ctx context.Context, udid string) error {
	set, _, err := shutdownIfBooted(ctx, udid)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, simctlArgs(set, "delete", udid)...)
	return err
}

// bootAndWait boots the device (tolerating an already-booted one) and blocks on
// bootstatus until its services are ready.
func bootAndWait(ctx context.Context, set, udid string) error {
	out, err := exec.CommandContext(ctx, "xcrun", simctlArgs(set, "boot", udid)...).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if !strings.Contains(msg, "already booted") && !strings.Contains(msg, "current state: Booted") {
			return fmt.Errorf("simctl boot: %w: %s", err, msg)
		}
	}
	_, err = xcrun(ctx, simctlArgs(set, "bootstatus", udid, "-b")...)
	return err
}

func shutdown(ctx context.Context, set, udid string) error {
	out, err := exec.CommandContext(ctx, "xcrun", simctlArgs(set, "shutdown", udid)...).CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "current state: Shutdown") {
			return nil
		}
		return fmt.Errorf("simctl shutdown: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// readDisabled returns the labels currently disabled in the device's system
// domain. A label absent from the output is enabled.
func readDisabled(ctx context.Context, set, udid string) (map[string]bool, error) {
	out, err := exec.CommandContext(ctx, "xcrun", simctlArgs(set, "spawn", udid,
		"launchctl", "print-disabled", "system")...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("launchctl print-disabled: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return parseDisabled(string(out)), nil
}

// parseDisabled reads `launchctl print-disabled` lines. Recent launchd prints
// `"com.apple.x" => disabled`; older builds print `=> true`/`=> false`.
func parseDisabled(output string) map[string]bool {
	set := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		open := strings.IndexByte(line, '"')
		if open < 0 {
			continue
		}
		rest := line[open+1:]
		closeQ := strings.IndexByte(rest, '"')
		if closeQ < 0 {
			continue
		}
		label := rest[:closeQ]
		arrow := strings.Index(rest[closeQ:], "=>")
		if arrow < 0 {
			continue
		}
		val := strings.TrimSpace(rest[closeQ+arrow+2:])
		if strings.HasPrefix(val, "disabled") || strings.HasPrefix(val, "true") {
			set[label] = true
		}
	}
	return set
}

// applyDelta disables then enables the given labels. launchctl must be the
// direct target of `simctl spawn`: a shell wrapper (`simctl spawn udid sh -c
// '...'`) does not propagate DYLD_ROOT_PATH, so the nested launchctl aborts with
// "DYLD_ROOT_PATH not set for simulator program". launchctl exits 0 even when it
// prints the benign "switch to user/foreground" note, so a non-zero exit is a
// real failure; failures are aggregated rather than aborting the whole profile.
func applyDelta(ctx context.Context, set, udid string, toDisable, toEnable []string, report reporter) error {
	total := len(toDisable) + len(toEnable)
	run := func(action, label string) error {
		out, err := exec.CommandContext(ctx, "xcrun", simctlArgs(set, "spawn", udid,
			"launchctl", action, "system/"+label)...).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s %s: %w: %s", action, label, err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	var failures []string
	done := 0
	step := func(action, label string) {
		if err := run(action, label); err != nil {
			failures = append(failures, err.Error())
		}
		done++
		// One process per label is slow (~30s for a full profile); a periodic
		// count reassures the caller that it has not hung.
		if done == total || done%20 == 0 {
			report.report(fmt.Sprintf("  %d/%d services updated", done, total))
		}
	}
	for _, l := range toDisable {
		step("disable", l)
	}
	for _, l := range toEnable {
		step("enable", l)
	}
	if len(failures) > 0 {
		return fmt.Errorf("%d/%d launchctl transitions failed: %s",
			len(failures), total, strings.Join(failures, "; "))
	}
	return nil
}

func waitShutdown(ctx context.Context, set, udid string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		d, err := findDevice(ctx, udid, set)
		if err != nil {
			return err
		}
		if d.State == "Shutdown" {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %s to shut down", udid)
}
