package main

import (
	"context"
	"os"
	"reflect"
	"testing"

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
