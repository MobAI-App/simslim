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
}

func xcrun(ctx context.Context, args ...string) ([]byte, error) {
	out, err := exec.CommandContext(ctx, "xcrun", args...).CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("xcrun %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return out, nil
}

func listDevices(ctx context.Context) ([]Device, error) {
	out, err := exec.CommandContext(ctx, "xcrun", "simctl", "list", "devices", "-j").Output()
	if err != nil {
		return nil, fmt.Errorf("simctl list: %w", err)
	}
	var parsed struct {
		Devices map[string][]struct {
			UDID        string `json:"udid"`
			Name        string `json:"name"`
			State       string `json:"state"`
			IsAvailable bool   `json:"isAvailable"`
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
			devices = append(devices, Device{UDID: d.UDID, Name: d.Name, State: d.State, OSVersion: osVersion(runtime)})
		}
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

func findDevice(ctx context.Context, udid string) (Device, error) {
	devices, err := listDevices(ctx)
	if err != nil {
		return Device{}, err
	}
	for _, d := range devices {
		if d.UDID == udid {
			return d, nil
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
// preventing simctl aliases such as "all" from entering these code paths.
func shutdownIfBooted(ctx context.Context, udid string) (bool, error) {
	device, err := findDevice(ctx, udid)
	if err != nil {
		return false, err
	}
	if device.State != "Booted" {
		return false, nil
	}
	if err := shutdown(ctx, udid); err != nil {
		return true, err
	}
	if err := waitShutdown(ctx, udid, shutdownTimeout); err != nil {
		return true, err
	}
	return true, nil
}

// cloneDevice temporarily shuts down a booted source because CoreSimulator can
// only clone a stable device, then restores the source's original boot state.
func cloneDevice(ctx context.Context, udid, name string) (newUDID string, err error) {
	name, err = normalizeSimulatorName(name)
	if err != nil {
		return "", err
	}
	wasBooted, err := shutdownIfBooted(ctx, udid)
	if err != nil {
		return "", err
	}
	if wasBooted {
		defer func() {
			restoreCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), bootTimeout)
			defer cancel()
			if restoreErr := bootAndWait(restoreCtx, udid); restoreErr != nil {
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

	out, err := xcrun(ctx, "simctl", "clone", udid, name)
	if err != nil {
		return "", err
	}
	return parseClonedUDID(out)
}

func renameDevice(ctx context.Context, udid, name string) error {
	if _, err := findDevice(ctx, udid); err != nil {
		return err
	}
	name, err := normalizeSimulatorName(name)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, "simctl", "rename", udid, name)
	return err
}

func eraseDevice(ctx context.Context, udid string) error {
	if _, err := shutdownIfBooted(ctx, udid); err != nil {
		return err
	}
	_, err := xcrun(ctx, "simctl", "erase", udid)
	return err
}

func deleteDevice(ctx context.Context, udid string) error {
	if _, err := shutdownIfBooted(ctx, udid); err != nil {
		return err
	}
	_, err := xcrun(ctx, "simctl", "delete", udid)
	return err
}

// bootAndWait boots the device (tolerating an already-booted one) and blocks on
// bootstatus until its services are ready.
func bootAndWait(ctx context.Context, udid string) error {
	out, err := exec.CommandContext(ctx, "xcrun", "simctl", "boot", udid).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if !strings.Contains(msg, "already booted") && !strings.Contains(msg, "current state: Booted") {
			return fmt.Errorf("simctl boot: %w: %s", err, msg)
		}
	}
	_, err = xcrun(ctx, "simctl", "bootstatus", udid, "-b")
	return err
}

func shutdown(ctx context.Context, udid string) error {
	out, err := exec.CommandContext(ctx, "xcrun", "simctl", "shutdown", udid).CombinedOutput()
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
func readDisabled(ctx context.Context, udid string) (map[string]bool, error) {
	out, err := exec.CommandContext(ctx, "xcrun", "simctl", "spawn", udid,
		"launchctl", "print-disabled", "system").CombinedOutput()
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
func applyDelta(ctx context.Context, udid string, toDisable, toEnable []string) error {
	run := func(action, label string) error {
		out, err := exec.CommandContext(ctx, "xcrun", "simctl", "spawn", udid,
			"launchctl", action, "system/"+label).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s %s: %w: %s", action, label, err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	var failures []string
	for _, l := range toDisable {
		if err := run("disable", l); err != nil {
			failures = append(failures, err.Error())
		}
	}
	for _, l := range toEnable {
		if err := run("enable", l); err != nil {
			failures = append(failures, err.Error())
		}
	}
	if len(failures) > 0 {
		return fmt.Errorf("%d/%d launchctl transitions failed: %s",
			len(failures), len(toDisable)+len(toEnable), strings.Join(failures, "; "))
	}
	return nil
}

func waitShutdown(ctx context.Context, udid string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		d, err := findDevice(ctx, udid)
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
