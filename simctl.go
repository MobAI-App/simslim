package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// Device is a simulator as reported by `simctl list`.
type Device struct {
	UDID      string
	Name      string
	State     string // "Booted" or "Shutdown"
	OSVersion string
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
