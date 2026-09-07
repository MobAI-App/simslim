package simslim

import (
	"context"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
)

// TestWatchSlimsEachBootedDeviceOnce verifies the scan slims a booted device
// exactly once and never touches a shutdown one, so a steady poll does not
// re-slim clones it already handled.
func TestWatchSlimsEachBootedDeviceOnce(t *testing.T) {
	dir := t.TempDir()
	xcrunPath := filepath.Join(dir, "xcrun")
	script := `#!/bin/sh
if [ "$*" = "simctl list devices -j" ]; then
  printf '%s\n' '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-1":[{"udid":"AAAA","name":"clone-1","state":"Booted","isAvailable":true,"dataPath":"/tmp/a"},{"udid":"BBBB","name":"clone-2","state":"Shutdown","isAvailable":true,"dataPath":"/tmp/b"}]}}'
  exit 0
fi
exit 0
`
	if err := os.WriteFile(xcrunPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var mu sync.Mutex
	slimmed := map[string]int{}
	fake := func(_ context.Context, _, udid string, _ Profile, _ Reporter) (bool, error) {
		mu.Lock()
		slimmed[udid]++
		mu.Unlock()
		return true, nil
	}

	seen := map[string]bool{}
	p := Profile{}
	for i := 0; i < 3; i++ { // repeated scans must not re-slim
		scanAndSlim(context.Background(), p, nil, fake, seen)
	}
	waitFor(t, func() bool { mu.Lock(); defer mu.Unlock(); return slimmed["AAAA"] == 1 })

	mu.Lock()
	defer mu.Unlock()
	if slimmed["AAAA"] != 1 {
		t.Fatalf("booted device slimmed %d times, want 1", slimmed["AAAA"])
	}
	if slimmed["BBBB"] != 0 {
		t.Fatalf("shutdown device slimmed %d times, want 0", slimmed["BBBB"])
	}
}

func waitFor(t *testing.T, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if cond() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("condition not met before deadline")
}
