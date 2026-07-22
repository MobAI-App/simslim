package simslim

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// DiskCleanupCategory describes one tightly allowlisted class of per-device
// data. Runtime files are deliberately outside this model: an iOS runtime is
// shared by many simulators and must only be managed by Xcode/simctl.
type DiskCleanupCategory struct {
	ID              string `json:"id"`
	Name            string `json:"name"`
	Description     string `json:"description"`
	Downside        string `json:"downside"`
	Recovery        string `json:"recovery"`
	Risk            string `json:"risk"`
	DefaultSelected bool   `json:"defaultSelected"`
	CanClean        bool   `json:"canClean"`
}

var DiskCleanupCategories = []DiskCleanupCategory{
	{
		ID:              "caches",
		Name:            "System & App Caches",
		Description:     "Generated cache files belonging to iOS and installed apps.",
		Downside:        "Next launches may be slower; downloaded or offline cache content can disappear.",
		Recovery:        "Old cache contents stay deleted; apps build new caches as needed.",
		Risk:            "Lower risk",
		DefaultSelected: true,
		CanClean:        true,
	},
	{
		ID:              "logs",
		Name:            "Logs & Diagnostics",
		Description:     "Unified logs, signposts, symbol text, crash logs, and app log folders.",
		Downside:        "Existing diagnostic and crash history is deleted.",
		Recovery:        "Old history stays deleted; future runs create new logs.",
		Risk:            "Lower risk",
		DefaultSelected: true,
		CanClean:        true,
	},
	{
		ID:              "temporary",
		Name:            "Temporary Files",
		Description:     "Files in simulator and app temporary directories.",
		Downside:        "Apps that misuse temporary storage may lose in-progress work.",
		Recovery:        "Old contents stay deleted; apps create new temporary files as needed.",
		Risk:            "Lower risk",
		DefaultSelected: true,
		CanClean:        true,
	},
	{
		ID:              "linguistic-data",
		Name:            "Downloaded Language Data",
		Description:     "On-demand language models used by Siri, Search, and text analysis.",
		Downside:        "Language-aware features may be limited until iOS downloads the package again.",
		Recovery:        "iOS downloads the language package again when a feature needs it.",
		Risk:            "Restored on demand",
		DefaultSelected: false,
		CanClean:        true,
	},
	{
		ID:              "required-siri-assets",
		Name:            "Required Siri Assets",
		Description:     "Siri understanding, speech, voice, and accessibility downloads restored by iOS.",
		Downside:        "Manual deletion is unsupported, and iOS promptly downloads required assets again.",
		Recovery:        "Required assets return automatically after boot.",
		Risk:            "System managed",
		DefaultSelected: false,
		CanClean:        false,
	},
}

type DiskCleanupCategoryMeasurement struct {
	DiskCleanupCategory
	Bytes   int64 `json:"bytes"`
	Targets int   `json:"targets"`
}

type DiskCleanupPlan struct {
	UDID           string                           `json:"udid"`
	TotalBytes     int64                            `json:"totalBytes"`
	CleanableBytes int64                            `json:"cleanableBytes"`
	Categories     []DiskCleanupCategoryMeasurement `json:"categories"`
	Storage        []DiskStorageMeasurement         `json:"storage"`
}

type DiskCleanupResult struct {
	UDID              string   `json:"udid"`
	CategoryIDs       []string `json:"categoryIds"`
	BeforeBytes       int64    `json:"beforeBytes"`
	AfterBytes        int64    `json:"afterBytes"`
	ReclaimedBytes    int64    `json:"reclaimedBytes"`
	WasBooted         bool     `json:"wasBooted"`
	BootStateRestored bool     `json:"bootStateRestored"`
}

func diskCleanupCategoryByID(id string) (DiskCleanupCategory, bool) {
	for _, category := range DiskCleanupCategories {
		if category.ID == id {
			return category, true
		}
	}
	return DiskCleanupCategory{}, false
}

// simulatorDataDirectory returns the device's on-disk data directory, taken
// straight from the dataPath simctl reports. It is validated as a real directory
// before the disk commands touch it
// every deletion is separately confined to it by clearDirectoryContents.
func simulatorDataDirectory(ctx context.Context, udid string) (Device, string, error) {
	device, err := FindDevice(ctx, udid, "")
	if err != nil {
		return Device{}, "", err
	}
	dataDirectory := device.DataPath
	if dataDirectory == "" {
		return Device{}, "", fmt.Errorf("simctl reported no data path for %s", udid)
	}
	info, err := os.Lstat(dataDirectory)
	if err != nil {
		return Device{}, "", fmt.Errorf("locate simulator data: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return Device{}, "", fmt.Errorf("simulator data path is not a real directory: %s", dataDirectory)
	}
	return device, dataDirectory, nil
}

func PlanDiskCleanup(ctx context.Context, udid string) (DiskCleanupPlan, error) {
	_, dataDirectory, err := simulatorDataDirectory(ctx, udid)
	if err != nil {
		return DiskCleanupPlan{}, err
	}
	return diskCleanupPlanAt(udid, dataDirectory)
}

func diskCleanupPlanAt(udid, dataDirectory string) (DiskCleanupPlan, error) {
	plan := DiskCleanupPlan{UDID: udid}
	for _, category := range DiskCleanupCategories {
		targets, err := diskCleanupTargets(dataDirectory, category.ID)
		if err != nil {
			return DiskCleanupPlan{}, fmt.Errorf("scan %s: %w", category.Name, err)
		}
		measurement := DiskCleanupCategoryMeasurement{
			DiskCleanupCategory: category,
			Targets:             len(targets),
		}
		for _, target := range targets {
			bytes, err := allocatedSize(target)
			if err != nil {
				return DiskCleanupPlan{}, fmt.Errorf("measure %s: %w", target, err)
			}
			measurement.Bytes += bytes
		}
		plan.TotalBytes += measurement.Bytes
		if category.CanClean {
			plan.CleanableBytes += measurement.Bytes
		}
		plan.Categories = append(plan.Categories, measurement)
	}
	storage, err := diskStorageMeasurements(dataDirectory)
	if err != nil {
		return DiskCleanupPlan{}, err
	}
	plan.Storage = storage
	return plan, nil
}

func CleanDeviceDisk(ctx context.Context, udid string, categoryIDs []string, preserveBootState bool) (DiskCleanupResult, error) {
	device, dataDirectory, err := simulatorDataDirectory(ctx, udid)
	if err != nil {
		return DiskCleanupResult{}, err
	}
	categoryIDs, err = ValidateDiskCleanupSelection(categoryIDs)
	if err != nil {
		return DiskCleanupResult{}, err
	}

	wasBooted := device.State == "Booted"
	if wasBooted {
		if _, _, err := shutdownIfBooted(ctx, udid); err != nil {
			return DiskCleanupResult{}, err
		}
	}

	result, cleanupErr := cleanDiskAt(udid, dataDirectory, categoryIDs)
	result.WasBooted = wasBooted
	if wasBooted && preserveBootState {
		if bootErr := BootAndWait(ctx, device.Set, udid); bootErr != nil {
			if cleanupErr != nil {
				return result, fmt.Errorf("%v; additionally could not restore boot state: %w", cleanupErr, bootErr)
			}
			return result, fmt.Errorf("disk cleanup finished, but could not restore boot state: %w", bootErr)
		}
		result.BootStateRestored = true
	}
	return result, cleanupErr
}

func cleanDiskAt(udid, dataDirectory string, categoryIDs []string) (DiskCleanupResult, error) {
	categoryIDs, err := ValidateDiskCleanupSelection(categoryIDs)
	if err != nil {
		return DiskCleanupResult{}, err
	}
	beforePlan, err := diskCleanupPlanAt(udid, dataDirectory)
	if err != nil {
		return DiskCleanupResult{}, err
	}
	beforeBytes := selectedCleanupBytes(beforePlan, categoryIDs)

	for _, id := range categoryIDs {
		targets, err := diskCleanupTargets(dataDirectory, id)
		if err != nil {
			return DiskCleanupResult{}, err
		}
		for _, target := range targets {
			if err := clearDirectoryContents(dataDirectory, target); err != nil {
				return DiskCleanupResult{}, fmt.Errorf("clean %s: %w", target, err)
			}
		}
	}

	afterPlan, err := diskCleanupPlanAt(udid, dataDirectory)
	if err != nil {
		return DiskCleanupResult{}, err
	}
	afterBytes := selectedCleanupBytes(afterPlan, categoryIDs)
	reclaimed := beforeBytes - afterBytes
	if reclaimed < 0 {
		reclaimed = 0
	}
	return DiskCleanupResult{
		UDID:           udid,
		CategoryIDs:    categoryIDs,
		BeforeBytes:    beforeBytes,
		AfterBytes:     afterBytes,
		ReclaimedBytes: reclaimed,
	}, nil
}

func ValidateDiskCleanupSelection(ids []string) ([]string, error) {
	seen := map[string]bool{}
	validated := make([]string, 0, len(ids))
	for _, id := range ids {
		id = strings.TrimSpace(id)
		if id == "" || seen[id] {
			continue
		}
		category, ok := diskCleanupCategoryByID(id)
		if !ok {
			return nil, fmt.Errorf("unknown disk cleanup category %q", id)
		}
		if !category.CanClean {
			return nil, fmt.Errorf("disk cleanup category %q is measured only and cannot be cleaned", id)
		}
		seen[id] = true
		validated = append(validated, id)
	}
	if len(validated) == 0 {
		return nil, fmt.Errorf("select at least one cleanable disk category")
	}
	sort.Strings(validated)
	return validated, nil
}

func selectedCleanupBytes(plan DiskCleanupPlan, ids []string) int64 {
	selected := map[string]bool{}
	for _, id := range ids {
		selected[id] = true
	}
	var total int64
	for _, category := range plan.Categories {
		if selected[category.ID] {
			total += category.Bytes
		}
	}
	return total
}

func diskCleanupTargets(dataDirectory, categoryID string) ([]string, error) {
	var targets []string
	var err error
	switch categoryID {
	case "caches":
		targets, err = findNamedDirectories(dataDirectory, "Caches", nil)
	case "temporary":
		targets, err = findNamedDirectories(dataDirectory, "tmp", map[string]bool{"Caches": true})
	case "logs":
		targets = []string{
			filepath.Join(dataDirectory, "Library", "Logs"),
			filepath.Join(dataDirectory, "var", "log"),
			filepath.Join(dataDirectory, "var", "db", "diagnostics"),
			filepath.Join(dataDirectory, "var", "db", "uuidtext"),
		}
		var discovered []string
		discovered, err = findNamedDirectories(dataDirectory, "Logs", map[string]bool{"Caches": true, "tmp": true})
		targets = append(targets, discovered...)
	case "linguistic-data":
		targets, err = linguisticDataTargets(dataDirectory)
	case "required-siri-assets":
		targets, err = requiredSiriAssetTargets(dataDirectory)
	default:
		return nil, fmt.Errorf("unknown disk cleanup category %q", categoryID)
	}
	if err != nil {
		return nil, err
	}
	return compactExistingTargets(dataDirectory, targets)
}

func findNamedDirectories(root, name string, excludedAncestors map[string]bool) ([]string, error) {
	var targets []string
	err := filepath.WalkDir(root, func(current string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.IsDir() || current == root {
			return nil
		}
		if isProtectedCleanupSubtree(entry.Name()) {
			return filepath.SkipDir
		}
		if excludedAncestors[entry.Name()] {
			return filepath.SkipDir
		}
		if entry.Name() == name {
			targets = append(targets, current)
			return filepath.SkipDir
		}
		return nil
	})
	return targets, err
}

// isProtectedCleanupSubtree keeps durable user content and system-managed
// assets out of name-based discovery. An app may legitimately create a folder
// named Caches, Logs, or tmp below Documents; its name alone does not make that
// content disposable.
func isProtectedCleanupSubtree(name string) bool {
	switch name {
	case "Documents", "Mobile Documents", "Media", "MobileAsset":
		return true
	default:
		return false
	}
}

func linguisticDataTargets(dataDirectory string) ([]string, error) {
	target := filepath.Join(
		dataDirectory,
		"private",
		"var",
		"MobileAsset",
		"AssetsV2",
		"com_apple_MobileAsset_LinguisticData",
	)
	return compactExistingTargets(dataDirectory, []string{target})
}

func requiredSiriAssetTargets(dataDirectory string) ([]string, error) {
	assetsRoot := filepath.Join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2")
	entries, err := os.ReadDir(assetsRoot)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	prefixes := []string{
		"com_apple_MobileAsset_UAF_Siri_",
		"com_apple_MobileAsset_TTS",
		"com_apple_MobileAsset_VoiceServices_",
		"com_apple_MobileAsset_VoiceTrigger",
	}
	var targets []string
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		for _, prefix := range prefixes {
			if strings.HasPrefix(entry.Name(), prefix) {
				targets = append(targets, filepath.Join(assetsRoot, entry.Name()))
				break
			}
		}
	}
	return targets, nil
}

func compactExistingTargets(root string, candidates []string) ([]string, error) {
	unique := map[string]bool{}
	var targets []string
	for _, candidate := range candidates {
		candidate = filepath.Clean(candidate)
		if err := requireDescendant(root, candidate); err != nil {
			return nil, err
		}
		info, err := os.Lstat(candidate)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || unique[candidate] {
			continue
		}
		if err := requireResolvedDescendant(root, candidate); err != nil {
			return nil, err
		}
		unique[candidate] = true
		targets = append(targets, candidate)
	}
	sort.Slice(targets, func(i, j int) bool {
		if len(targets[i]) != len(targets[j]) {
			return len(targets[i]) < len(targets[j])
		}
		return targets[i] < targets[j]
	})
	compacted := targets[:0]
	for _, target := range targets {
		covered := false
		for _, parent := range compacted {
			relative, _ := filepath.Rel(parent, target)
			if relative != "." && relative != ".." && !strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
				covered = true
				break
			}
		}
		if !covered {
			compacted = append(compacted, target)
		}
	}
	return compacted, nil
}

func requireDescendant(root, target string) error {
	root = filepath.Clean(root)
	target = filepath.Clean(target)
	relative, err := filepath.Rel(root, target)
	if err != nil {
		return fmt.Errorf("resolve cleanup path: %w", err)
	}
	if relative == "." || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return fmt.Errorf("refusing cleanup path outside simulator data: %s", target)
	}
	return nil
}

// requireResolvedDescendant rejects targets whose existing path components
// traverse a symlink outside root. Lexical containment alone cannot catch an
// intermediate symlink such as data/var -> /some/other/location.
func requireResolvedDescendant(root, target string) error {
	resolvedRoot, err := filepath.EvalSymlinks(root)
	if err != nil {
		return fmt.Errorf("resolve cleanup root: %w", err)
	}
	resolvedTarget, err := filepath.EvalSymlinks(target)
	if err != nil {
		return fmt.Errorf("resolve cleanup target: %w", err)
	}
	if err := requireDescendant(resolvedRoot, resolvedTarget); err != nil {
		return fmt.Errorf("refusing symlinked cleanup path %s: %w", target, err)
	}
	return nil
}

func allocatedSize(root string) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(current string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if stat, ok := info.Sys().(*syscall.Stat_t); ok {
			total += stat.Blocks * 512
		} else {
			total += info.Size()
		}
		return nil
	})
	return total, err
}

func clearDirectoryContents(dataDirectory, target string) error {
	if err := requireDescendant(dataDirectory, target); err != nil {
		return err
	}
	info, err := os.Lstat(target)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("refusing to clear non-directory target %s", target)
	}
	if err := requireResolvedDescendant(dataDirectory, target); err != nil {
		return err
	}
	entries, err := os.ReadDir(target)
	if err != nil {
		return err
	}
	for _, entry := range entries {
		child := filepath.Join(target, entry.Name())
		if err := requireDescendant(dataDirectory, child); err != nil {
			return err
		}
		if err := os.RemoveAll(child); err != nil {
			return err
		}
	}
	return nil
}
