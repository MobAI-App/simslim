package simslim

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseRuntime(t *testing.T) {
	for _, tt := range []struct{ runtime, platform, version string }{
		{"com.apple.CoreSimulator.SimRuntime.iOS-26-5", "iOS", "26.5"},
		{"com.apple.CoreSimulator.SimRuntime.tvOS-18-5", "tvOS", "18.5"},
		{"com.apple.CoreSimulator.SimRuntime.watchOS-11-5-1", "watchOS", "11.5.1"},
		{"com.apple.CoreSimulator.SimRuntime.watchOS-26-0", "watchOS", "26.0"},
		{"com.apple.CoreSimulator.SimRuntime.xrOS-26-0", "", "?"},
		{"com.apple.CoreSimulator.SimRuntime.not-iOS-26-0", "", "?"},
		{"com.apple.CoreSimulator.SimRuntime.iOS-", "", "?"},
		{"iOS-26-5", "", "?"},
		{"", "", "?"},
	} {
		t.Run(tt.runtime, func(t *testing.T) {
			platform, version := parseRuntime(tt.runtime)
			if platform != tt.platform || version != tt.version {
				t.Fatalf("parseRuntime(%q) = (%q, %q), want (%q, %q)", tt.runtime, platform, version, tt.platform, tt.version)
			}
		})
	}
}

func TestListAndFindDevicesAcrossPlatformsAndSets(t *testing.T) {
	ResetDeviceSets()
	t.Cleanup(ResetDeviceSets)
	RegisterDeviceSet("/custom/devices")
	dir := t.TempDir()
	script := `#!/bin/sh
case "$*" in
  "simctl list devices -j")
    printf '%s\n' '{"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5":[{"udid":"PHONE","name":"Phone","state":"Shutdown","isAvailable":true}],
      "com.apple.CoreSimulator.SimRuntime.tvOS-26-0":[{"udid":"TV","name":"Living room","state":"Booted","isAvailable":true,"dataPath":"/tmp/tv/data"},{"udid":"UNAVAILABLE","isAvailable":false}],
      "com.apple.CoreSimulator.SimRuntime.xrOS-26-0":[{"udid":"VISION","isAvailable":true}]
    }}' ;;
  "simctl --set testing list devices -j")
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.watchOS-11-5":[{"udid":"WATCH","name":"Renamed device","state":"Booted","isAvailable":true,"dataPath":"/tmp/watch/data"}]}}' ;;
  "simctl --set /custom/devices list devices -j")
    printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.tvOS-18-5":[{"udid":"CUSTOM","name":"Custom TV","state":"Shutdown","isAvailable":true}]}}' ;;
  *) exit 99 ;;
esac
`
	if err := os.WriteFile(filepath.Join(dir, "xcrun"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	devices, err := ListDevices(context.Background())
	if err != nil || len(devices) != 4 {
		t.Fatalf("ListDevices = (%v, %v), want 4 supported, available devices", devices, err)
	}
	want := map[string]Device{
		"PHONE":  {Platform: "iOS", OSVersion: "26.5", Set: "default"},
		"TV":     {Platform: "tvOS", OSVersion: "26.0", Set: "default", DataPath: "/tmp/tv/data"},
		"WATCH":  {Platform: "watchOS", OSVersion: "11.5", Set: "testing", DataPath: "/tmp/watch/data"},
		"CUSTOM": {Platform: "tvOS", OSVersion: "18.5", Set: "/custom/devices"},
	}
	for _, d := range devices {
		w, ok := want[d.UDID]
		if !ok || d.Platform != w.Platform || d.OSVersion != w.OSVersion || d.Set != w.Set || d.DataPath != w.DataPath {
			t.Errorf("unexpected device: %+v", d)
		}
		found, err := FindDevice(context.Background(), d.UDID, d.Set)
		if err != nil || found != d {
			t.Errorf("FindDevice(%q, %q) = (%+v, %v), want %+v", d.UDID, d.Set, found, err, d)
		}
		encoded, err := json.Marshal(DeviceSummary{Device: d})
		if err != nil || !strings.Contains(string(encoded), `"platform":"`+w.Platform+`"`) {
			t.Errorf("device summary lost platform: %s (%v)", encoded, err)
		}
	}
}

func TestDeviceSupportsPersistentOverrides(t *testing.T) {
	for _, tt := range []struct {
		platform, version string
		want              bool
	}{
		{"", "18.5", true}, // backward-compatible Device literals
		{"iOS", "18.4", false}, {"iOS", "18.5", true},
		{"tvOS", "18.4", false}, {"tvOS", "18.5", true},
		{"watchOS", "10.5", false}, {"watchOS", "11.4", false},
		{"watchOS", "11.5", true}, {"watchOS", "11.5.1", true},
		{"watchOS", "26.0", true}, {"tvOS", "26.0", true},
		{"watchOS", "?", false}, {"watchOS", "11", false},
		{"watchOS", "26.-1", false}, {"xrOS", "26.0", false},
	} {
		d := Device{Platform: tt.platform, OSVersion: tt.version}
		t.Run(d.RuntimeName(), func(t *testing.T) {
			if got := d.SupportsPersistentOverrides(); got != tt.want {
				t.Errorf("SupportsPersistentOverrides = %t, want %t", got, tt.want)
			}
		})
	}
}

func TestSlimAndRestoreAppleTVAndWatch(t *testing.T) {
	for _, runtime := range []string{"tvOS-18-5", "watchOS-11-5", "tvOS-26-0", "watchOS-26-5"} {
		t.Run(runtime, func(t *testing.T) {
			const udid = "00000000-0000-0000-0000-0000000000F1"
			useTempStoreRoot(t)
			fakeSimctl(t, udid, runtime, "Shutdown")
			ctx := context.Background()
			changed, err := EnableSlim(ctx, "default", udid, Profile{}, nil)
			if err != nil || !changed {
				t.Fatalf("EnableSlim = (%t, %v)", changed, err)
			}
			st, _, err := ReadStatus(ctx, udid)
			if err != nil || !st.Persistent || st.ManagedDisabled != st.ManagedTotal {
				t.Fatalf("ReadStatus = (%+v, %v), want persistent full slim", st, err)
			}
			changed, err = EnableSlim(ctx, "default", udid, Profile{}, nil)
			if err != nil || changed {
				t.Fatalf("second EnableSlim = (%t, %v), want idempotent", changed, err)
			}
			if _, err := DisableSlim(ctx, "default", udid, nil); err != nil {
				t.Fatal(err)
			}
			st, _, err = ReadStatus(ctx, udid)
			if err != nil || st.ManagedDisabled != 0 {
				t.Fatalf("status after off = (%+v, %v), want stock", st, err)
			}
		})
	}
}

func TestOlderAppleTVAndWatchRequireNoReboot(t *testing.T) {
	for _, runtime := range []string{"tvOS-18-3", "watchOS-10-5", "watchOS-11-4"} {
		t.Run(runtime, func(t *testing.T) {
			const udid = "00000000-0000-0000-0000-0000000000F2"
			useTempStoreRoot(t)
			logPath := fakeSimctl(t, udid, runtime, "Shutdown")
			ctx := context.Background()
			changed, err := EnableSlim(ctx, "default", udid, Profile{}, nil)
			platform, version := parseRuntime("com.apple.CoreSimulator.SimRuntime." + runtime)
			if err == nil || changed || !strings.Contains(err.Error(), platform+" "+version) || !strings.Contains(err.Error(), "--no-reboot") {
				t.Fatalf("EnableSlim = (%t, %v), want platform-specific rejection", changed, err)
			}
			if calls := xcrunCalls(t, logPath); len(calls) != 1 || calls[0] != "simctl list devices -j" {
				t.Fatalf("rejected device was mutated: %v", calls)
			}
			changed, err = EnableSlimNoReboot(ctx, "default", udid, Profile{}, nil)
			if err != nil || !changed {
				t.Fatalf("EnableSlimNoReboot = (%t, %v)", changed, err)
			}
			if calls := strings.Join(xcrunCalls(t, logPath), "\n"); strings.Contains(calls, "simctl shutdown") {
				t.Fatal("no-reboot slimming shut the device down")
			}
			st, _, err := ReadStatus(ctx, udid)
			if err != nil || st.Persistent || st.ManagedDisabled != st.ManagedTotal {
				t.Fatalf("ReadStatus = (%+v, %v), want session-only full slim", st, err)
			}
			if _, err := DisableSlim(ctx, "default", udid, nil); err != nil {
				t.Fatalf("DisableSlim must still work on older runtimes: %v", err)
			}
		})
	}
}

func TestNewPlatformsRejectLostOverrides(t *testing.T) {
	for _, runtime := range []string{"tvOS-26-0", "watchOS-26-5"} {
		t.Run(runtime, func(t *testing.T) {
			const udid = "00000000-0000-0000-0000-0000000000F3"
			useTempStoreRoot(t)
			logPath := fakeSimctl(t, udid, runtime, "Shutdown")
			t.Setenv("SIMSLIM_TEST_IGNORE_STORE", "1")
			// Model a runtime that accepts disables but forgets them on reboot.
			xcrunPath := filepath.Join(filepath.Dir(logPath), "xcrun")
			script := strings.Replace(fakeXcrunScript, "printf Shutdown", "rm -f \"$SIMSLIM_TEST_LIVE\"/*\n    printf Shutdown", 1)
			if err := os.WriteFile(xcrunPath, []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			labels := twoSlimmableLabels(t)
			_, err := ensure(context.Background(), "default", udid, map[string]bool{labels[0]: true}, nil)
			if err == nil || !strings.Contains(err.Error(), "did not survive the reboot") {
				t.Fatalf("ensure = %v, want persistence verification failure", err)
			}
		})
	}
}

func TestRepairCloneRejectsDifferentPlatformsAtSameVersion(t *testing.T) {
	useTempStoreRoot(t)
	logPath := fakeSimctl(t, testSourceUDID, "iOS-26-5", "Shutdown")
	dir := t.TempDir()
	devices := map[string]any{"devices": map[string]any{
		"com.apple.CoreSimulator.SimRuntime.iOS-26-5": []map[string]any{
			{"udid": testSourceUDID, "state": "Booted", "isAvailable": true, "dataPath": dir},
		},
		"com.apple.CoreSimulator.SimRuntime.watchOS-26-5": []map[string]any{
			{"udid": testCloneUDID, "state": "Booted", "isAvailable": true, "dataPath": dir},
		},
	}}
	encoded, err := json.Marshal(devices)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SIMSLIM_TEST_DEVICES", string(encoded))
	err = RepairClonedDevice(context.Background(), testSourceUDID, testCloneUDID)
	if err == nil || !strings.Contains(err.Error(), "source and clone runtimes differ (iOS 26.5 and watchOS 26.5)") {
		t.Fatalf("RepairClonedDevice = %v, want platform mismatch", err)
	}
	for _, call := range xcrunCalls(t, logPath) {
		if call != "simctl list devices -j" {
			t.Errorf("cross-platform repair mutated a simulator: %s", call)
		}
	}
}

func TestWatchProfileKeepsHomedEnabled(t *testing.T) {
	p := Profile{Keep: map[string]bool{"com.apple.apsd": true}}
	watch := Device{Platform: "watchOS", OSVersion: "26.5"}
	for _, platform := range []string{"iOS", "tvOS", ""} {
		if !p.DesiredForDevice(Device{Platform: platform})["com.apple.homed"] {
			t.Errorf("homed unexpectedly excluded on %q", platform)
		}
	}
	if desired := p.DesiredForDevice(watch); desired["com.apple.homed"] || desired["com.apple.apsd"] {
		t.Fatalf("Watch profile disabled a required or kept label: %v", desired)
	}
	const udid = "00000000-0000-0000-0000-0000000000F4"
	useTempStoreRoot(t)
	logPath := fakeSimctl(t, udid, "watchOS-26-5", "Shutdown")
	if err := writeDisabledStore(udid, []string{"com.apple.homed"}, nil); err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	if _, err := EnableSlim(ctx, "default", udid, p, nil); err != nil {
		t.Fatal(err)
	}
	st, disabled, err := ReadStatus(ctx, udid)
	if err != nil || disabled["com.apple.homed"] || st.ManagedTotal != len(SlimmableSet())-1 || st.ManagedDisabled != st.ManagedTotal-1 {
		t.Fatalf("Watch status = (%+v, %v), homed disabled = %t", st, err, disabled["com.apple.homed"])
	}
	verified, err := VerifyProfile(ctx, udid, p)
	if err != nil || !verified.OK {
		t.Fatalf("Watch profile verification = (%+v, %v)", verified, err)
	}
	if _, err := EnableSlimNoReboot(ctx, "default", udid, p, nil); err != nil {
		t.Fatal(err)
	}
	for _, call := range xcrunCalls(t, logPath) {
		if strings.Contains(call, "launchctl disable system/com.apple.homed") || strings.Contains(call, "launchctl bootout system/com.apple.homed") {
			t.Fatalf("Watch slimming tried to disable required service: %s", call)
		}
	}
}
