package simslim

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestWatchDeviceDirs verifies a device created after the watch starts is
// reported with its set and the devices already there are not, a deleted
// device is forgotten, and a set directory created later is attached on retry.
func TestWatchDeviceDirs(t *testing.T) {
	dir := t.TempDir()
	missing := filepath.Join(t.TempDir(), "missing")
	if err := os.Mkdir(filepath.Join(dir, "OLD"), 0o755); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	created := make(chan deviceDir, 4)
	done := make(chan struct{})
	go func() {
		watchDeviceDirs(ctx, map[string]string{dir: "default", missing: "testing"}, 10*time.Millisecond, func(d deviceDir) { created <- d })
		close(done)
	}()
	expect := func(want deviceDir) {
		t.Helper()
		select {
		case d := <-created:
			if d != want {
				t.Fatalf("reported %v, want %v", d, want)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("%v was not reported", want)
		}
	}

	select {
	case d := <-created:
		t.Fatalf("an existing device was reported: %v", d)
	case <-time.After(50 * time.Millisecond):
	}
	newDir := filepath.Join(dir, "NEW")
	if err := os.Mkdir(newDir, 0o755); err != nil {
		t.Fatal(err)
	}
	expect(deviceDir{path: newDir, set: "default"})

	// Deleted and created again, the device is new again: it was forgotten.
	if err := os.Remove(newDir); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	if err := os.Mkdir(newDir, 0o755); err != nil {
		t.Fatal(err)
	}
	expect(deviceDir{path: newDir, set: "default"})

	// The missing set directory appears with a device already in it.
	if err := os.MkdirAll(filepath.Join(missing, "CLONE"), 0o755); err != nil {
		t.Fatal(err)
	}
	expect(deviceDir{path: filepath.Join(missing, "CLONE"), set: "testing"})

	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("the watch did not stop when ctx was cancelled")
	}
}
