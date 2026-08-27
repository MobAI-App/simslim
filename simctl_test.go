package simslim

import (
	"os"
	"path/filepath"
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

func TestParseBatchOK(t *testing.T) {
	output := strings.Join([]string{
		"Warning: Please switch to user/foreground/com.apple.siriactionsd service identifier (rdar://78126471)",
		"simslim-ok com.apple.siriactionsd",
		"simslim-fail com.apple.assistantd",
		"  simslim-ok com.apple.suggestd",
		"simslim-ok ",
		"unrelated noise",
		"",
	}, "\n")
	got := parseBatchOK(output)
	want := map[string]bool{
		"com.apple.siriactionsd": true,
		"com.apple.suggestd":     true,
	}
	if len(got) != len(want) {
		t.Fatalf("parseBatchOK() = %v, want %v", got, want)
	}
	for label := range want {
		if !got[label] {
			t.Errorf("parseBatchOK() missing %q", label)
		}
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
