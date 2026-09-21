package simslim

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const ShutdownTimeout = 30 * time.Second

// BootTimeout bounds a full boot-and-reconfigure (boots twice on a first slim); a
// var, not a const, so `--boot-timeout` / SIMSLIM_BOOT_TIMEOUT can raise it for CI.
var BootTimeout = 10 * time.Minute

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
func RegisterDeviceSet(value string) {
	for _, set := range knownDeviceSets() {
		if set.token == value {
			return
		}
	}
	extraDeviceSets = append(extraDeviceSets, deviceSetInfo{token: value, name: value})
}

// ExtraDeviceSetTokens returns the tokens registered with RegisterDeviceSet,
// beyond the well-known default and testing sets.
func ExtraDeviceSetTokens() []string {
	var tokens []string
	for _, set := range extraDeviceSets {
		tokens = append(tokens, set.token)
	}
	return tokens
}

// ResetDeviceSets drops every set registered with RegisterDeviceSet.
func ResetDeviceSets() {
	extraDeviceSets = nil
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
		return nil, listError(err)
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

// listError surfaces xcrun's stderr, which Output (kept separate so stdout
// stays clean JSON) parks in ExitError.Stderr; without it a failed listing
// reports only an exit code.
func listError(err error) error {
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return formatListError(err, string(exitErr.Stderr))
	}
	return fmt.Errorf("simctl list: %w", err)
}

// formatListError appends stderr to the listing error and, when xcrun cannot
// find simctl at all — xcode-select pointing at the Command Line Tools, which
// do not ship it — says how to select a full Xcode.
func formatListError(err error, stderr string) error {
	stderr = strings.TrimSpace(stderr)
	if stderr == "" {
		return fmt.Errorf("simctl list: %w", err)
	}
	if strings.Contains(stderr, `unable to find utility "simctl"`) {
		return fmt.Errorf("simctl list: %w: %s (simctl ships with full Xcode, not the Command Line Tools; select one with `sudo xcode-select -s /Applications/Xcode.app`)", err, stderr)
	}
	return fmt.Errorf("simctl list: %w: %s", err, stderr)
}

// The default set is mandatory; a secondary set that cannot be listed (e.g. it
// does not exist) is skipped rather than failing the whole listing.
func ListDevices(ctx context.Context) ([]Device, error) {
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
func FindDevice(ctx context.Context, udid, set string) (Device, error) {
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

func NormalizeSimulatorName(name string) (string, error) {
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
	device, err := FindDevice(ctx, udid, "")
	if err != nil {
		return "", false, err
	}
	if device.State != "Booted" {
		return device.Set, false, nil
	}
	if err := Shutdown(ctx, device.Set, udid); err != nil {
		return device.Set, true, err
	}
	if err := WaitShutdown(ctx, device.Set, udid, ShutdownTimeout); err != nil {
		return device.Set, true, err
	}
	return device.Set, true, nil
}

func RenameDevice(ctx context.Context, udid, name string) error {
	device, err := FindDevice(ctx, udid, "")
	if err != nil {
		return err
	}
	name, err = NormalizeSimulatorName(name)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, simctlArgs(device.Set, "rename", udid, name)...)
	return err
}

func EraseDevice(ctx context.Context, udid string) error {
	set, _, err := shutdownIfBooted(ctx, udid)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, simctlArgs(set, "erase", udid)...)
	return err
}

func DeleteDevice(ctx context.Context, udid string) error {
	set, _, err := shutdownIfBooted(ctx, udid)
	if err != nil {
		return err
	}
	_, err = xcrun(ctx, simctlArgs(set, "delete", udid)...)
	return err
}

// bootAndWait boots the device (tolerating an already-booted one) and blocks on
// bootstatus until its services are ready.
func BootAndWait(ctx context.Context, set, udid string) error {
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

func Shutdown(ctx context.Context, set, udid string) error {
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

// SpawnTimeout bounds a single `simctl spawn launchctl` transition. Right
// after a first boot — especially on older Intel hosts — the simulator is
// saturated by data migration and Spotlight indexing, and an individual spawn
// can stall for many minutes. A per-spawn bound turns one stuck spawn into a
// retryable failure instead of letting it consume the whole reconfigure
// budget; the label is retried on a later pass once the device has settled.
// A var, not a const, so SIMSLIM_SPAWN_TIMEOUT can raise it for slow hosts.
var SpawnTimeout = 2 * time.Minute

// applyPasses is how many times applyDelta walks the remaining labels.
// Disables are persistent, so each pass only retries what previous passes
// failed; on a freshly booted device the later passes run against a warm
// launchd and typically finish in seconds per label.
const applyPasses = 3

// spawnWorkers bounds how many `simctl spawn launchctl` transitions run at
// once. Overrides are independent launchd writes, so they parallelize cleanly,
// and a small pool hides most of the per-spawn simctl latency (~4x on an M1)
// without hammering a simulator that is still settling after its first boot.
const spawnWorkers = 8

// liveDisable is the applyDelta action that disables a label and then boots
// the running service out of launchd, so the daemon stops now and cannot
// respawn for the rest of the boot session. `disable` alone only blocks the
// next bootstrap; `bootout` is what removes the live job.
const liveDisable = "bootout"

// bootoutGone is launchctl's exit status when the service to boot out is not
// loaded ("No such process"), which is already the state liveDisable wants.
const bootoutGone = 3

// applyDelta disables then enables the given labels; disableAction is
// "disable" (override only, applied at the next boot) or liveDisable. Each
// transition is its own `simctl spawn launchctl`, run through a pool of
// spawnWorkers so the per-spawn simctl latency overlaps instead of adding up.
// launchctl exits 0 even when it prints the benign "switch to user/foreground"
// note, so a non-zero exit is a real failure; failures are collected and
// retried on later passes rather than aborting the whole profile.
func applyDelta(ctx context.Context, set, udid string, toDisable, toEnable []string, disableAction string, report Reporter) error {
	type transition struct{ action, label string }
	pending := make([]transition, 0, len(toDisable)+len(toEnable))
	for _, l := range toDisable {
		pending = append(pending, transition{disableAction, l})
	}
	for _, l := range toEnable {
		pending = append(pending, transition{"enable", l})
	}
	total := len(pending)
	launchctl := func(verb, label string) ([]byte, error) {
		spawnCtx, cancel := context.WithTimeout(ctx, SpawnTimeout)
		defer cancel()
		return exec.CommandContext(spawnCtx, "xcrun", simctlArgs(set, "spawn", udid,
			"launchctl", verb, "system/"+label)...).CombinedOutput()
	}
	run := func(action, label string) error {
		verb := action
		if action == liveDisable {
			verb = "disable"
		}
		out, err := launchctl(verb, label)
		if err != nil {
			return fmt.Errorf("%s %s: %w: %s", verb, label, err, strings.TrimSpace(string(out)))
		}
		if action != liveDisable {
			return nil
		}
		out, err = launchctl("bootout", label)
		var exitErr *exec.ExitError
		if err != nil && !(errors.As(err, &exitErr) && exitErr.ExitCode() == bootoutGone) {
			return fmt.Errorf("bootout %s: %w: %s", label, err, strings.TrimSpace(string(out)))
		}
		return nil
	}

	done := 0
	var failures []string
	for pass := 1; pass <= applyPasses && len(pending) > 0; pass++ {
		if pass > 1 {
			report.report(fmt.Sprintf("  retrying %d failed services (pass %d/%d)...",
				len(pending), pass, applyPasses))
		}
		type result struct {
			t   transition
			err error
		}
		// Buffered for every transition, so a worker never blocks on the
		// reader and the pool keeps draining even while progress is printed.
		results := make(chan result, len(pending))
		sem := make(chan struct{}, spawnWorkers)
		var wg sync.WaitGroup
		for _, t := range pending {
			if ctx.Err() != nil {
				break
			}
			sem <- struct{}{}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { <-sem }()
				results <- result{t, run(t.action, t.label)}
			}()
		}
		go func() {
			wg.Wait()
			close(results)
		}()

		var failed []transition
		failures = failures[:0]
		// Reporting happens here, on the one goroutine that owns Reporter.
		for r := range results {
			if r.err != nil {
				failed = append(failed, r.t)
				failures = append(failures, r.err.Error())
				continue
			}
			done++
			if done == total || done%20 == 0 {
				report.report(fmt.Sprintf("  %d/%d services updated", done, total))
			}
		}
		if ctx.Err() != nil {
			// The overall reconfigure budget is exhausted; stop instead of
			// burning through the rest of the labels.
			return fmt.Errorf("%d/%d launchctl transitions incomplete: %w",
				total-done, total, ctx.Err())
		}
		pending = failed
	}
	if len(pending) > 0 {
		return fmt.Errorf("%d/%d launchctl transitions failed after %d passes: %s",
			len(pending), total, applyPasses, strings.Join(failures, "; "))
	}
	return nil
}

func WaitShutdown(ctx context.Context, set, udid string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		d, err := FindDevice(ctx, udid, set)
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
