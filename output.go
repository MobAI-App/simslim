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

// ServicesOutput is returned by `enable` and `disable`: the managed daemons the
// command changed in the running boot session, and the profile file it saved.
type ServicesOutput struct {
	Action       string   `json:"action"` // "enable" or "disable"
	UDID         string   `json:"udid"`
	Live         bool     `json:"live"`                   // false: the simulator is not booted, only the profile was saved
	Labels       []string `json:"labels"`                 // daemons enabled, or stopped by disable
	NotStarted   []string `json:"notStarted,omitempty"`   // enable: re-enabled, but launchd starts them only at the next boot
	StillEnabled []string `json:"stillEnabled,omitempty"` // disable: kept running for another fully enabled category or the platform
	Saved        string   `json:"saved,omitempty"`        // the profile file --save created or updated
}

// DroppedCategory lists the managed launchd labels a category has disabled on a
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

// ScreenshotOutput is returned by `screenshot`: the PNG path written for a
// booted simulator, so the GUI can render its live screen in the device grid.
type ScreenshotOutput struct {
	UDID string `json:"udid"`
	Name string `json:"name,omitempty"`
	Path string `json:"path"`
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

// TopSim is one booted simulator's live resource snapshot for `simslim top`.
type TopSim struct {
	Device
	ManagedDisabled *int         `json:"managedDisabled,omitempty"`
	ManagedTotal    int          `json:"managedTotal"`
	StatusError     string       `json:"statusError,omitempty"`
	Memory          *Measurement `json:"memory,omitempty"`
	MemoryError     string       `json:"memoryError,omitempty"`
	DiskBytes       *int64       `json:"diskBytes,omitempty"`
}

// TopOutput is the fleet view: every booted simulator plus the summed footprint
// that decides how many more fit.
type TopOutput struct {
	Sims       []TopSim `json:"sims"`
	TotalBytes int64    `json:"totalBytes"`
}

// TopProcesses is one simulator's per-daemon breakdown, the top drill-down.
type TopProcesses struct {
	UDID       string    `json:"udid"`
	Name       string    `json:"name,omitempty"`
	Processes  []Process `json:"processes"`
	TotalBytes int64     `json:"totalBytes"`
}
