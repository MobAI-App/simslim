package simslim

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// DiskStorageMeasurement is a read-only breakdown of durable per-simulator
// storage. These rows are deliberately separate from cleanup categories so
// documents, app bundles, and user data can never become selected for deletion.
type DiskStorageMeasurement struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
	Bytes       int64  `json:"bytes"`
}

var diskStorageCategories = []DiskStorageMeasurement{
	{
		ID:          "installed-apps",
		Name:        "Installed Apps",
		Description: "Developer-installed app and test-runner bundles. Built-in apps live in the shared runtime.",
	},
	{
		ID:          "documents",
		Name:        "Documents",
		Description: "Files in app and app-group Documents directories.",
	},
	{
		ID:          "app-data",
		Name:        "App Data",
		Description: "Preferences, databases, and support files outside Documents and cleanup categories.",
	},
	{
		ID:          "user-media",
		Name:        "User Media",
		Description: "Photos, videos, downloads, and other files in the simulator media library.",
	},
}

func diskStorageMeasurements(dataDirectory string) ([]DiskStorageMeasurement, error) {
	measurements := make([]DiskStorageMeasurement, 0, len(diskStorageCategories))
	for _, category := range diskStorageCategories {
		measurement := category
		var err error
		switch category.ID {
		case "installed-apps":
			measurement.Bytes, err = allocatedSizeOfExistingDirectories(
				dataDirectory,
				[]string{filepath.Join(dataDirectory, "Containers", "Bundle", "Application")},
			)
		case "documents":
			var targets []string
			targets, err = appDocumentTargets(dataDirectory)
			if err == nil {
				measurement.Bytes, err = allocatedSizeOfExistingDirectories(dataDirectory, targets)
			}
		case "app-data":
			measurement.Bytes, err = appDataSize(dataDirectory)
		case "user-media":
			measurement.Bytes, err = allocatedSizeOfExistingDirectories(
				dataDirectory,
				[]string{filepath.Join(dataDirectory, "Media")},
			)
		default:
			err = fmt.Errorf("unknown disk storage category %q", category.ID)
		}
		if err != nil {
			return nil, fmt.Errorf("measure %s: %w", category.Name, err)
		}
		measurements = append(measurements, measurement)
	}
	return measurements, nil
}

func appDocumentTargets(dataDirectory string) ([]string, error) {
	var candidates []string
	for _, root := range []string{
		filepath.Join(dataDirectory, "Containers", "Data", "Application"),
		filepath.Join(dataDirectory, "Containers", "Shared", "AppGroup"),
	} {
		entries, err := os.ReadDir(root)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			if entry.IsDir() {
				candidates = append(candidates, filepath.Join(root, entry.Name(), "Documents"))
			}
		}
	}
	return compactExistingTargets(dataDirectory, candidates)
}

func appDataSize(dataDirectory string) (int64, error) {
	excluded := map[string]bool{
		"Caches":    true,
		"Documents": true,
		"Logs":      true,
		"tmp":       true,
	}
	var total int64
	for _, root := range []string{
		filepath.Join(dataDirectory, "Containers", "Data", "Application"),
		filepath.Join(dataDirectory, "Containers", "Shared", "AppGroup"),
	} {
		info, err := os.Lstat(root)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return 0, err
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			continue
		}
		if err := requireResolvedDescendant(dataDirectory, root); err != nil {
			return 0, err
		}
		bytes, err := allocatedSizeExcludingNames(root, excluded)
		if err != nil {
			return 0, err
		}
		total += bytes
	}
	return total, nil
}

func allocatedSizeOfExistingDirectories(root string, candidates []string) (int64, error) {
	targets, err := compactExistingTargets(root, candidates)
	if err != nil {
		return 0, err
	}
	var total int64
	for _, target := range targets {
		bytes, err := allocatedSize(target)
		if err != nil {
			return 0, err
		}
		total += bytes
	}
	return total, nil
}

func allocatedSizeExcludingNames(root string, excluded map[string]bool) (int64, error) {
	var total int64
	err := filepath.WalkDir(root, func(current string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if current != root && entry.IsDir() && excluded[entry.Name()] {
			return filepath.SkipDir
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
