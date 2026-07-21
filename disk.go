package main

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// deviceDiskUsage reports allocated filesystem blocks for one exact simulator
// device directory. It deliberately resolves the UDID through simctl first so
// aliases such as "all" can never become filesystem paths.
func deviceDiskUsage(ctx context.Context, udid string) (DiskMeasurement, error) {
	_, dataDirectory, err := simulatorDataDirectory(ctx, udid)
	if err != nil {
		return DiskMeasurement{}, err
	}
	devicePath := filepath.Dir(dataDirectory)
	out, err := exec.CommandContext(ctx, "du", "-sk", devicePath).CombinedOutput()
	if err != nil {
		return DiskMeasurement{}, fmt.Errorf("measure simulator disk usage: %w: %s", err, strings.TrimSpace(string(out)))
	}
	bytes, err := parseDUDiskUsage(out)
	if err != nil {
		return DiskMeasurement{}, err
	}
	return DiskMeasurement{Bytes: bytes}, nil
}

func parseDUDiskUsage(output []byte) (int64, error) {
	fields := strings.Fields(string(output))
	if len(fields) == 0 {
		return 0, fmt.Errorf("du returned no disk usage")
	}
	kib, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil || kib < 0 {
		return 0, fmt.Errorf("parse du disk usage %q", fields[0])
	}
	return kib * 1024, nil
}
