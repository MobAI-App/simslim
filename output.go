package main

import (
	"encoding/json"
	"fmt"
	"os"
)

// DeviceSummary is the stable, machine-readable representation used by the
// macOS app and other integrations. managedDisabled is omitted for shutdown
// simulators because launchd state can only be read while a simulator is booted.
type DeviceSummary struct {
	Device
	ManagedDisabled *int         `json:"managedDisabled,omitempty"`
	ManagedTotal    int          `json:"managedTotal"`
	StatusError     string       `json:"statusError,omitempty"`
	Memory          *Measurement `json:"memory,omitempty"`
	MemoryError     string       `json:"memoryError,omitempty"`
}

type StatusOutput struct {
	Status
	Verdict string            `json:"verdict"`
	Dropped []DroppedCategory `json:"dropped,omitempty"` // only when `status --dropped` is requested
}

// DroppedCategory lists the managed daemons a category has disabled on a
// simulator, alongside the feature that stops working as a result.
type DroppedCategory struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	Downside string   `json:"downside"`
	Labels   []string `json:"labels"`
}

// SimulatorMutationOutput is returned by simulator-management commands so the
// GUI can refresh and, for clone, select the newly created device.
type SimulatorMutationOutput struct {
	Action     string `json:"action"`
	UDID       string `json:"udid"`
	Name       string `json:"name,omitempty"`
	SourceUDID string `json:"sourceUdid,omitempty"`
}

type DiskMeasurement struct {
	Bytes int64 `json:"bytes"`
}

func writeJSON(value any) error {
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(value)
}

// jsonOption removes one optional --json flag while rejecting duplicates.
// Keeping this independent of flag.FlagSet lets callers put --json before or
// after a UDID, which is friendlier for programmatic use.
func jsonOption(args []string) (bool, []string, error) {
	jsonOutput := false
	remaining := make([]string, 0, len(args))
	for _, arg := range args {
		if arg != "--json" {
			remaining = append(remaining, arg)
			continue
		}
		if jsonOutput {
			return false, nil, fmt.Errorf("--json may only be specified once")
		}
		jsonOutput = true
	}
	return jsonOutput, remaining, nil
}
