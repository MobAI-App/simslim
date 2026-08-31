package simslim

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureRejectsIOS183BeforeBoot(t *testing.T) {
	const udid = "00000000-0000-0000-0000-000000000034"
	dir := t.TempDir()
	logPath := filepath.Join(dir, "xcrun.log")
	xcrunPath := filepath.Join(dir, "xcrun")
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$SIMSLIM_XCRUN_LOG"
if [ "$*" = "simctl list devices -j" ]; then
  printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-3":[{"udid":"00000000-0000-0000-0000-000000000034","name":"Issue 34","state":"Shutdown","isAvailable":true,"dataPath":"/tmp/issue-34"}]}}'
  exit 0
fi
exit 99
`
	if err := os.WriteFile(xcrunPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SIMSLIM_XCRUN_LOG", logPath)

	var label string
	for label = range SlimmableSet() {
		break
	}
	changed, err := ensure(context.Background(), "default", udid, map[string]bool{label: true}, nil)
	if changed {
		t.Fatal("ensure reported a change on an unsupported runtime")
	}
	const want = "iOS 18.3 runtime cannot persist launchd disable overrides across reboot; simslim requires iOS 18.5 or newer"
	if err == nil || err.Error() != want {
		t.Fatalf("ensure error = %v, want %q", err, want)
	}
	log, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if got := strings.TrimSpace(string(log)); got != "simctl list devices -j" {
		t.Fatalf("xcrun calls = %q, want only the read-only device lookup", got)
	}
}

func TestCountLost(t *testing.T) {
	managed := map[string]bool{"a": true, "b": true, "c": true}
	tests := []struct {
		name    string
		after   map[string]bool
		desired map[string]bool
		want    int
	}{
		{"all persisted", map[string]bool{"a": true, "b": true}, map[string]bool{"a": true, "b": true}, 0},
		{"nothing persisted", map[string]bool{}, map[string]bool{"a": true, "b": true}, 2},
		{"partially persisted", map[string]bool{"a": true}, map[string]bool{"a": true, "b": true}, 1},
		{"stale disable not re-enabled", map[string]bool{"a": true, "c": true}, map[string]bool{"a": true}, 1},
		{"unmanaged labels ignored", map[string]bool{"a": true, "com.example.x": true}, map[string]bool{"a": true}, 0},
		{"stock desired and reached", map[string]bool{}, map[string]bool{}, 0},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := countLost(tt.after, tt.desired, managed); got != tt.want {
				t.Errorf("countLost() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestPersistentOverridesSupported(t *testing.T) {
	tests := []struct {
		v    string
		want bool
	}{
		{"17.5", false},
		{"18.3", false},
		{"18.4.1", false},
		{"18.5", true},
		{"18.5.1", true},
		{"26.5", true},
		{"18", false},
		{"", false},
		{"garbage", false},
	}
	for _, tt := range tests {
		if got := persistentOverridesSupported(tt.v); got != tt.want {
			t.Errorf("persistentOverridesSupported(%q) = %t, want %t", tt.v, got, tt.want)
		}
	}
}
