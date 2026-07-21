package main

import (
	"path/filepath"
	"testing"
)

func TestDiskStorageMeasurementsSeparateDurableDataFromCleanup(t *testing.T) {
	dataDirectory := filepath.Join(t.TempDir(), "data")
	installedApp := filepath.Join(
		dataDirectory,
		"Containers",
		"Bundle",
		"Application",
		"APP-CONTAINER",
		"Example.app",
		"Example",
	)
	documents := filepath.Join(
		dataDirectory,
		"Containers",
		"Data",
		"Application",
		"DATA-CONTAINER",
		"Documents",
	)
	appSupport := filepath.Join(
		dataDirectory,
		"Containers",
		"Data",
		"Application",
		"DATA-CONTAINER",
		"Library",
		"Application Support",
	)
	cacheDirectory := filepath.Join(
		dataDirectory,
		"Containers",
		"Data",
		"Application",
		"DATA-CONTAINER",
		"Library",
		"Caches",
	)
	logDirectory := filepath.Join(
		dataDirectory,
		"Containers",
		"Data",
		"Application",
		"DATA-CONTAINER",
		"Library",
		"Logs",
	)
	tempDirectory := filepath.Join(
		dataDirectory,
		"Containers",
		"Data",
		"Application",
		"DATA-CONTAINER",
		"tmp",
	)
	mediaDirectory := filepath.Join(dataDirectory, "Media", "DCIM", "100APPLE")

	writeTestFile(t, installedApp, 32*1024)
	writeTestFile(t, filepath.Join(documents, "project.data"), 24*1024)
	writeTestFile(t, filepath.Join(appSupport, "database.sqlite"), 20*1024)
	writeTestFile(t, filepath.Join(cacheDirectory, "response.cache"), 64*1024)
	writeTestFile(t, filepath.Join(logDirectory, "app.log"), 64*1024)
	writeTestFile(t, filepath.Join(tempDirectory, "work.tmp"), 64*1024)
	writeTestFile(t, filepath.Join(mediaDirectory, "photo.heic"), 28*1024)

	measurements, err := diskStorageMeasurements(dataDirectory)
	if err != nil {
		t.Fatalf("diskStorageMeasurements() error = %v", err)
	}
	byID := map[string]DiskStorageMeasurement{}
	for _, measurement := range measurements {
		byID[measurement.ID] = measurement
	}
	for _, id := range []string{"installed-apps", "documents", "app-data", "user-media"} {
		if byID[id].Bytes == 0 {
			t.Errorf("storage category %q should report test data", id)
		}
	}

	appDataBefore := byID["app-data"].Bytes
	writeTestFile(t, filepath.Join(cacheDirectory, "larger.cache"), 512*1024)
	measurements, err = diskStorageMeasurements(dataDirectory)
	if err != nil {
		t.Fatalf("diskStorageMeasurements() after cache growth error = %v", err)
	}
	for _, measurement := range measurements {
		if measurement.ID == "app-data" && measurement.Bytes != appDataBefore {
			t.Errorf(
				"app-data must exclude cleanable caches: before=%d after=%d",
				appDataBefore,
				measurement.Bytes,
			)
		}
	}
}

func TestDiskCleanupPlanIncludesReadOnlyStorageBreakdown(t *testing.T) {
	dataDirectory := filepath.Join(t.TempDir(), "data")
	writeTestFile(
		t,
		filepath.Join(dataDirectory, "Containers", "Bundle", "Application", "APP", "Example.app", "Example"),
		4096,
	)
	writeTestFile(
		t,
		filepath.Join(dataDirectory, "Containers", "Data", "Application", "DATA", "Documents", "keep.txt"),
		4096,
	)

	plan, err := diskCleanupPlanAt("TEST-UDID", dataDirectory)
	if err != nil {
		t.Fatalf("diskCleanupPlanAt() error = %v", err)
	}
	if len(plan.Storage) != len(diskStorageCategories) {
		t.Fatalf("storage rows = %d, want %d", len(plan.Storage), len(diskStorageCategories))
	}
	if plan.CleanableBytes != 0 {
		t.Fatalf("durable storage must never count as cleanable: %d", plan.CleanableBytes)
	}
}
