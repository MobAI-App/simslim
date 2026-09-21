package simslim

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestNormalizeSimulatorName(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		want      string
		wantError bool
	}{
		{name: "ordinary", input: "QA iPhone", want: "QA iPhone"},
		{name: "trims whitespace", input: "  QA iPhone  ", want: "QA iPhone"},
		{name: "unicode", input: "Démo 📱", want: "Démo 📱"},
		{name: "empty", input: "   ", wantError: true},
		{name: "embedded control", input: "QA\nPhone", wantError: true},
		{name: "too long", input: strings.Repeat("a", 129), wantError: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := NormalizeSimulatorName(tt.input)
			if (err != nil) != tt.wantError {
				t.Fatalf("NormalizeSimulatorName() error = %v, wantError %v", err, tt.wantError)
			}
			if got != tt.want {
				t.Errorf("NormalizeSimulatorName() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestFormatListError(t *testing.T) {
	exit72 := errors.New("exit status 72")
	tests := []struct {
		name    string
		stderr  string
		want    []string
		wantNot []string
	}{
		{
			name:    "no stderr keeps the bare error",
			stderr:  "",
			want:    []string{"simctl list: exit status 72"},
			wantNot: []string{"xcode-select"},
		},
		{
			name:    "whitespace-only stderr keeps the bare error",
			stderr:  "  \n",
			want:    []string{"simctl list: exit status 72"},
			wantNot: []string{"xcode-select"},
		},
		{
			name:   "stderr is appended",
			stderr: "An error was encountered processing the command\n",
			want:   []string{"simctl list: exit status 72: An error was encountered processing the command"},
		},
		{
			name:   "missing simctl adds the xcode-select hint",
			stderr: `xcrun: error: unable to find utility "simctl", not a developer tool or in PATH`,
			want: []string{
				`unable to find utility "simctl"`,
				"sudo xcode-select -s",
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatListError(exit72, tt.stderr).Error()
			for _, want := range tt.want {
				if !strings.Contains(got, want) {
					t.Errorf("formatListError() = %q, missing %q", got, want)
				}
			}
			for _, wantNot := range tt.wantNot {
				if strings.Contains(got, wantNot) {
					t.Errorf("formatListError() = %q, should not contain %q", got, wantNot)
				}
			}
			if !errors.Is(formatListError(exit72, tt.stderr), exit72) {
				t.Errorf("formatListError() does not wrap the original error")
			}
		})
	}
}

func TestParseClonedUDID(t *testing.T) {
	const udid = "00000000-0000-0000-0000-000000000001"
	got, err := parseClonedUDID([]byte("\n" + udid + "\n"))
	if err != nil {
		t.Fatalf("parseClonedUDID() error = %v", err)
	}
	if got != udid {
		t.Errorf("parseClonedUDID() = %q, want %q", got, udid)
	}

	for _, invalid := range []string{"", "not-a-udid", "00000000-0000-0000-0000-00000000000Z"} {
		if _, err := parseClonedUDID([]byte(invalid)); err == nil {
			t.Errorf("parseClonedUDID(%q) unexpectedly succeeded", invalid)
		}
	}
}

func TestResetClonedLaunchServicesAt(t *testing.T) {
	dataDirectory := filepath.Join(t.TempDir(), "data")
	lsdDirectory := filepath.Join(dataDirectory, "var", "db", "lsd")
	if err := os.MkdirAll(lsdDirectory, 0o755); err != nil {
		t.Fatal(err)
	}

	removed := []string{
		"com.apple.LaunchServices-20971544-v2.csstore",
		"com.apple.LaunchServices-20971544-v2.csstore-shm",
		"com.apple.LaunchServices-20971544-v2.csstore-wal",
	}
	preserved := []string{
		"SystemDataOnly-com.apple.LaunchServices-20971544-v2.csstore",
		"com.apple.LaunchServicesAppProtectionStore.plist",
		"unrelated.db",
	}
	for _, name := range append(append([]string{}, removed...), preserved...) {
		if err := os.WriteFile(filepath.Join(lsdDirectory, name), []byte("test"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := resetClonedLaunchServicesAt(dataDirectory); err != nil {
		t.Fatalf("resetClonedLaunchServicesAt() error = %v", err)
	}
	for _, name := range removed {
		if _, err := os.Stat(filepath.Join(lsdDirectory, name)); !os.IsNotExist(err) {
			t.Errorf("generated store %q still exists; stat error = %v", name, err)
		}
	}
	for _, name := range preserved {
		if _, err := os.Stat(filepath.Join(lsdDirectory, name)); err != nil {
			t.Errorf("unrelated file %q was not preserved: %v", name, err)
		}
	}
}

func TestResetClonedLaunchServicesAtAllowsMissingStore(t *testing.T) {
	dataDirectory := filepath.Join(t.TempDir(), "data")
	if err := os.MkdirAll(dataDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := resetClonedLaunchServicesAt(dataDirectory); err != nil {
		t.Fatalf("resetClonedLaunchServicesAt() error = %v", err)
	}
}

func TestResetClonedLaunchServicesAtRejectsSymlink(t *testing.T) {
	root := t.TempDir()
	dataDirectory := filepath.Join(root, "data")
	externalDirectory := filepath.Join(root, "external")
	if err := os.MkdirAll(filepath.Join(dataDirectory, "var", "db"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(externalDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(externalDirectory, filepath.Join(dataDirectory, "var", "db", "lsd")); err != nil {
		t.Fatal(err)
	}

	err := resetClonedLaunchServicesAt(dataDirectory)
	if err == nil || !strings.Contains(err.Error(), "not a real directory") {
		t.Fatalf("resetClonedLaunchServicesAt() error = %v, want symlink rejection", err)
	}
}

// TestApplyDeltaRunsTransitionsConcurrentlyButBounded drives applyDelta
// against a fake xcrun that records how many spawns are in flight while it
// works. The peak proves both halves of the contract: transitions really do
// overlap (the whole point of the pool), and never more than spawnWorkers of
// them at once, so a simulator still settling after a first boot is not
// hammered.
func TestApplyDeltaRunsTransitionsConcurrentlyButBounded(t *testing.T) {
	dir := t.TempDir()
	inFlight := filepath.Join(dir, "inflight")
	peaks := filepath.Join(dir, "peaks")
	if err := os.Mkdir(inFlight, 0o755); err != nil {
		t.Fatal(err)
	}
	// Each spawn logs its arguments, marks itself present, records how many
	// peers it sees, holds long enough for the rest of its wave to arrive,
	// then leaves.
	script := `#!/bin/sh
printf '%s\n' "$*" >> "$SIMSLIM_XCRUN_LOG"
: > "$SIMSLIM_INFLIGHT/$$"
ls "$SIMSLIM_INFLIGHT" | wc -l >> "$SIMSLIM_PEAKS"
sleep 0.2
rm -f "$SIMSLIM_INFLIGHT/$$"
exit 0
`
	if err := os.WriteFile(filepath.Join(dir, "xcrun"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("SIMSLIM_INFLIGHT", inFlight)
	t.Setenv("SIMSLIM_PEAKS", peaks)
	logPath := filepath.Join(dir, "xcrun.log")
	t.Setenv("SIMSLIM_XCRUN_LOG", logPath)

	labels := make([]string, 3*spawnWorkers)
	for i := range labels {
		labels[i] = fmt.Sprintf("com.apple.probe%d", i)
	}
	if err := applyDelta(context.Background(), "default", "UDID", labels, nil, "disable", nil); err != nil {
		t.Fatalf("applyDelta: %v", err)
	}

	log, err := os.ReadFile(peaks)
	if err != nil {
		t.Fatal(err)
	}
	peak := 0
	for _, line := range strings.Fields(string(log)) {
		n, err := strconv.Atoi(line)
		if err != nil {
			t.Fatalf("unparsable peak %q: %v", line, err)
		}
		peak = max(peak, n)
	}
	if peak <= 1 {
		t.Errorf("peak concurrency = %d, want transitions to overlap", peak)
	}
	if peak > spawnWorkers {
		t.Errorf("peak concurrency = %d, want at most spawnWorkers (%d)", peak, spawnWorkers)
	}

	// Bounding the pool must not cost coverage: every label gets exactly the
	// one transition it was queued for, whatever order the workers ran in.
	want := make(map[string]bool, len(labels))
	for _, l := range labels {
		want["simctl spawn UDID launchctl disable system/"+l] = true
	}
	got := map[string]int{}
	for _, call := range xcrunCalls(t, logPath) {
		got[call]++
	}
	if len(got) != len(want) {
		t.Errorf("saw %d distinct transitions, want %d", len(got), len(want))
	}
	for call := range want {
		if got[call] != 1 {
			t.Errorf("transition %q ran %d times, want exactly 1", call, got[call])
		}
	}
}
