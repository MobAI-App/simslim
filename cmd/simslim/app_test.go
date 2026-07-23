package main

import (
	"context"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/mobai-app/simslim"
)

// runApp runs the CLI with stdout/stderr discarded so command output does not
// pollute the test log. It uses `profiles`, which touches neither simctl nor the
// macOS-only guard, to exercise flag and argument parsing through the real tree.
func runApp(t *testing.T, args ...string) error {
	t.Helper()
	devnull, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatalf("open %s: %v", os.DevNull, err)
	}
	defer devnull.Close()
	oldStdout, oldStderr := os.Stdout, os.Stderr
	os.Stdout, os.Stderr = devnull, devnull
	defer func() { os.Stdout, os.Stderr = oldStdout, oldStderr }()
	return newApp().Run(context.Background(), append([]string{"simslim"}, args...))
}

// TestAppRegistersDeviceSets verifies the global --set flag registers the extra
// device sets, whether it appears before or after the subcommand, in equals
// form, comma-separated, or repeated (last-wins), and that a blank value errors.
func TestAppRegistersDeviceSets(t *testing.T) {
	tests := []struct {
		name      string
		args      []string
		wantExtra []string // tokens registered beyond the well-known sets
		wantError bool
	}{
		{name: "absent", args: []string{"profiles"}},
		{name: "before command", args: []string{"--set", "/a", "profiles"}, wantExtra: []string{"/a"}},
		{name: "after command", args: []string{"profiles", "--set", "/a"}, wantExtra: []string{"/a"}},
		{name: "equals form", args: []string{"profiles", "--set=/a"}, wantExtra: []string{"/a"}},
		{name: "comma-separated", args: []string{"--set", "/a,/b", "profiles"}, wantExtra: []string{"/a", "/b"}},
		{name: "comma trims blanks", args: []string{"--set=/a, ,/b", "profiles"}, wantExtra: []string{"/a", "/b"}},
		{name: "repeat is last-wins", args: []string{"--set", "/a", "--set", "/b", "profiles"}, wantExtra: []string{"/b"}},
		{name: "well-known not duplicated", args: []string{"--set", "testing", "profiles"}},
		{name: "blank value errors", args: []string{"--set", "  ", "profiles"}, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			simslim.ResetDeviceSets()
			defer simslim.ResetDeviceSets()
			err := runApp(t, tt.args...)
			if (err != nil) != tt.wantError {
				t.Fatalf("Run(%v) error = %v, wantError %v", tt.args, err, tt.wantError)
			}
			gotExtra := simslim.ExtraDeviceSetTokens()
			if !reflect.DeepEqual(gotExtra, tt.wantExtra) {
				t.Errorf("registered extra sets = %v, want %v", gotExtra, tt.wantExtra)
			}
		})
	}
}

// TestAppBootTimeoutFlag verifies --boot-timeout and its SIMSLIM_BOOT_TIMEOUT env
// source override simslim.BootTimeout, and that a non-positive duration is rejected.
func TestAppBootTimeoutFlag(t *testing.T) {
	const def = 10 * time.Minute
	tests := []struct {
		name      string
		args      []string
		env       string // value for SIMSLIM_BOOT_TIMEOUT, "" to leave unset
		want      time.Duration
		wantError bool
	}{
		{name: "absent keeps default", args: []string{"profiles"}, want: def},
		{name: "before command", args: []string{"--boot-timeout", "15m", "profiles"}, want: 15 * time.Minute},
		{name: "after command", args: []string{"profiles", "--boot-timeout", "15m"}, want: 15 * time.Minute},
		{name: "equals form", args: []string{"profiles", "--boot-timeout=20m"}, want: 20 * time.Minute},
		{name: "from env", args: []string{"profiles"}, env: "12m", want: 12 * time.Minute},
		{name: "flag overrides env", args: []string{"profiles", "--boot-timeout", "9m"}, env: "12m", want: 9 * time.Minute},
		{name: "zero rejected", args: []string{"profiles", "--boot-timeout", "0"}, want: def, wantError: true},
		{name: "negative rejected", args: []string{"profiles", "--boot-timeout", "-1m"}, want: def, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			simslim.ResetDeviceSets()
			defer simslim.ResetDeviceSets()
			orig := simslim.BootTimeout
			simslim.BootTimeout = def
			defer func() { simslim.BootTimeout = orig }()
			if tt.env != "" {
				t.Setenv("SIMSLIM_BOOT_TIMEOUT", tt.env)
			}
			err := runApp(t, tt.args...)
			if (err != nil) != tt.wantError {
				t.Fatalf("Run(%v) error = %v, wantError %v", tt.args, err, tt.wantError)
			}
			if simslim.BootTimeout != tt.want {
				t.Errorf("BootTimeout = %v, want %v", simslim.BootTimeout, tt.want)
			}
		})
	}
}

// TestAppFlagParsing covers per-command flag parsing: a flag may appear before
// or after a positional argument, --json rejects duplicates, an unknown flag is
// rejected, and an unknown positional fails validation.
func TestAppFlagParsing(t *testing.T) {
	tests := []struct {
		name      string
		args      []string
		wantError bool
	}{
		{name: "json flag", args: []string{"profiles", "--json"}},
		{name: "flag before positional", args: []string{"profiles", "--json", "siri"}},
		{name: "flag after positional", args: []string{"profiles", "siri", "--json"}},
		{name: "duplicate json rejected", args: []string{"profiles", "--json", "--json", "siri"}, wantError: true},
		{name: "unknown flag rejected", args: []string{"profiles", "--nope"}, wantError: true},
		{name: "unknown category rejected", args: []string{"profiles", "does-not-exist"}, wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			simslim.ResetDeviceSets()
			defer simslim.ResetDeviceSets()
			err := runApp(t, tt.args...)
			if (err != nil) != tt.wantError {
				t.Fatalf("Run(%v) error = %v, wantError %v", tt.args, err, tt.wantError)
			}
		})
	}
}
