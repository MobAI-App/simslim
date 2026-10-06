package simslim

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// launchdJobDirs are the RuntimeRoot directories holding the job plists that
// launchd_sim bootstraps into the simulator's system domain.
var launchdJobDirs = []string{"System/Library/LaunchDaemons", "System/Library/LaunchAgents"}

// unloadChunk bounds how many plist paths go into one `launchctl unload`, so
// the argument list stays far below ARG_MAX however long the profile grows.
const unloadChunk = 64

func parseRuntimeRoot(out []byte, runtimeID string) (string, error) {
	var parsed struct {
		Runtimes []struct {
			Identifier  string `json:"identifier"`
			RuntimeRoot string `json:"runtimeRoot"`
		} `json:"runtimes"`
	}
	if err := json.Unmarshal(out, &parsed); err != nil {
		return "", fmt.Errorf("parse simctl list runtimes: %w", err)
	}
	for _, r := range parsed.Runtimes {
		if r.Identifier == runtimeID && r.RuntimeRoot != "" {
			return r.RuntimeRoot, nil
		}
	}
	return "", fmt.Errorf("runtime %s has no runtimeRoot", runtimeID)
}

// launchdJobPlists maps each label to the job plist that defines exactly that
// label. A plist is only used when its own Label key matches, so a renamed or
// shared file can never unload a daemon outside the allowlist; labels without
// a matching plist are left for the per-label path.
func launchdJobPlists(ctx context.Context, root string, labels []string, plistLabel func(context.Context, string) (string, error)) map[string]string {
	paths := make(map[string]string, len(labels))
	for _, label := range labels {
		if ctx.Err() != nil {
			break
		}
		for _, dir := range launchdJobDirs {
			path := filepath.Join(root, dir, label+".plist")
			if _, err := os.Stat(path); err != nil {
				continue
			}
			if got, err := plistLabel(ctx, path); err == nil && got == label {
				paths[label] = path
				break
			}
		}
	}
	return paths
}

// readPlistLabel reads a job plist's Label with the host's plutil, which
// handles both XML and binary plists.
func readPlistLabel(ctx context.Context, path string) (string, error) {
	out, err := exec.CommandContext(ctx, "plutil", "-extract", "Label", "raw", "-o", "-", path).Output()
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(string(out)), nil
}

// parseLaunchctlList reads `launchctl list` rows: "PID<TAB>Status<TAB>Label",
// with "-" as the PID of a loaded job that is not running.
func parseLaunchctlList(output string) map[string]bool {
	loaded := map[string]bool{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(line)
		if len(fields) != 3 || fields[2] == "Label" {
			continue
		}
		loaded[fields[2]] = true
	}
	return loaded
}

// stillToStop keeps the labels the batch did not finish: no disable override
// yet, or still loaded. A few jobs stay listed even with their override in
// place (on a slim visionOS 27.0 simulator, for example siri.context.service
// and TrustedPeersHelper), so they always take the per-label bootout; the old
// path booted out every label, so this is never more work than before.
func stillToStop(labels []string, disabled, loaded map[string]bool) []string {
	var rest []string
	for _, l := range labels {
		if !disabled[l] || loaded[l] {
			rest = append(rest, l)
		}
	}
	return rest
}
