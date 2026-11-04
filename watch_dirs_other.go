//go:build !darwin

package simslim

import (
	"context"
	"time"
)

// watchDeviceDirs has no kqueue to watch with off macOS, where simslim does not
// run anyway; the scan alone finds new devices.
func watchDeviceDirs(ctx context.Context, setDirs map[string]string, retry time.Duration, created func(deviceDir)) {
	<-ctx.Done()
}
