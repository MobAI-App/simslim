package simslim

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

// DoctorOutput reports whether each required feature survives the device's
// current slimming. OK is false when any required feature has a disabled daemon.
type DoctorOutput struct {
	UDID     string          `json:"udid,omitempty"`
	OK       bool            `json:"ok"`
	Features []FeatureStatus `json:"features"`
}

// FeatureStatus is one feature's verdict: the daemons it needs that are down.
type FeatureStatus struct {
	ID       string   `json:"id"`
	Name     string   `json:"name"`
	OK       bool     `json:"ok"`
	Disabled []string `json:"disabled,omitempty"`
}

type DiskMeasurement struct {
	Bytes int64 `json:"bytes"`
}
