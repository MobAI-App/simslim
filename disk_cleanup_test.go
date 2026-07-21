package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiskCleanupCategoriesAreUniqueAndSafeByDefault(t *testing.T) {
	seen := map[string]bool{}
	for _, category := range DiskCleanupCategories {
		if category.ID == "" || seen[category.ID] {
			t.Fatalf("invalid or duplicate disk cleanup category %q", category.ID)
		}
		seen[category.ID] = true
		if category.DefaultSelected && !category.CanClean {
			t.Fatalf("measured-only category %q must not be selected by default", category.ID)
		}
	}
	if category, ok := diskCleanupCategoryByID("required-siri-assets"); !ok || category.CanClean {
		t.Fatal("required Siri assets must remain measured-only")
	}
	if category, ok := diskCleanupCategoryByID("linguistic-data"); !ok || !category.CanClean || category.DefaultSelected {
		t.Fatal("downloaded language data must be cleanable but opt-in")
	}
}

func TestDiskCleanupRecoveryModelsStayDistinct(t *testing.T) {
	for _, id := range []string{"caches", "logs", "temporary"} {
		category, ok := diskCleanupCategoryByID(id)
		if !ok {
			t.Fatalf("missing cleanup category %q", id)
		}
		if !strings.Contains(category.Recovery, "deleted") {
			t.Errorf("cleanup category %q must say old contents stay deleted: %q", id, category.Recovery)
		}
	}

	assets, ok := diskCleanupCategoryByID("required-siri-assets")
	if !ok {
		t.Fatal("missing required Siri asset category")
	}
	if !strings.Contains(assets.Recovery, "return automatically") {
		t.Errorf("system assets must describe automatic restoration: %q", assets.Recovery)
	}
	language, ok := diskCleanupCategoryByID("linguistic-data")
	if !ok || !strings.Contains(language.Recovery, "downloads") {
		t.Errorf("language data must describe on-demand recovery: %q", language.Recovery)
	}
	if language.Risk != "Restored on demand" {
		t.Errorf("language data must label its restoration behavior: %q", language.Risk)
	}
}

func TestDiskCleanupPlanAndCleanStayInsideAllowlist(t *testing.T) {
	dataDirectory := filepath.Join(t.TempDir(), "data")
	cacheDirectory := filepath.Join(dataDirectory, "Library", "Caches")
	tempDirectory := filepath.Join(dataDirectory, "Containers", "Data", "Application", "A", "tmp")
	diagnosticsDirectory := filepath.Join(dataDirectory, "var", "db", "diagnostics")
	uuidTextDirectory := filepath.Join(dataDirectory, "var", "db", "uuidtext")
	requiredSiriDirectory := filepath.Join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "com_apple_MobileAsset_UAF_Siri_Understanding")
	linguisticDirectory := filepath.Join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "com_apple_MobileAsset_LinguisticData")
	unrelatedAssetDirectory := filepath.Join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "com_apple_MobileAsset_PKITrustStore")
	appDocumentDirectory := filepath.Join(dataDirectory, "Containers", "Data", "Application", "A", "Documents")
	userNamedCache := filepath.Join(appDocumentDirectory, "Caches", "keep-cache.bin")
	userNamedLogs := filepath.Join(appDocumentDirectory, "Logs", "keep-log.txt")
	userNamedTemp := filepath.Join(appDocumentDirectory, "tmp", "keep-temp.bin")
	assetNamedCache := filepath.Join(requiredSiriDirectory, "Caches", "keep-asset-cache.bin")

	writeTestFile(t, filepath.Join(cacheDirectory, "cache.bin"), 32*1024)
	writeTestFile(t, filepath.Join(tempDirectory, "temp.bin"), 16*1024)
	writeTestFile(t, filepath.Join(diagnosticsDirectory, "log.tracev3"), 24*1024)
	writeTestFile(t, filepath.Join(uuidTextDirectory, "symbols"), 24*1024)
	writeTestFile(t, filepath.Join(requiredSiriDirectory, "model.bin"), 64*1024)
	writeTestFile(t, filepath.Join(linguisticDirectory, "language-model.bin"), 48*1024)
	writeTestFile(t, filepath.Join(unrelatedAssetDirectory, "trust.bin"), 64*1024)
	writeTestFile(t, filepath.Join(appDocumentDirectory, "user.db"), 64*1024)
	writeTestFile(t, userNamedCache, 32*1024)
	writeTestFile(t, userNamedLogs, 32*1024)
	writeTestFile(t, userNamedTemp, 32*1024)
	writeTestFile(t, assetNamedCache, 32*1024)

	plan, err := diskCleanupPlanAt("TEST-UDID", dataDirectory)
	if err != nil {
		t.Fatalf("diskCleanupPlanAt() error = %v", err)
	}
	measurements := map[string]DiskCleanupCategoryMeasurement{}
	for _, measurement := range plan.Categories {
		measurements[measurement.ID] = measurement
	}
	for _, id := range []string{"caches", "logs", "temporary", "linguistic-data", "required-siri-assets"} {
		if measurements[id].Bytes == 0 {
			t.Errorf("category %q should report test data", id)
		}
	}
	if plan.CleanableBytes == 0 || plan.TotalBytes <= plan.CleanableBytes {
		t.Errorf("unexpected plan totals: cleanable=%d total=%d", plan.CleanableBytes, plan.TotalBytes)
	}

	result, err := cleanDiskAt("TEST-UDID", dataDirectory, []string{"temporary", "logs", "caches", "linguistic-data"})
	if err != nil {
		t.Fatalf("cleanDiskAt() error = %v", err)
	}
	if result.ReclaimedBytes == 0 {
		t.Error("cleanup should reclaim allocated bytes")
	}
	for _, removed := range []string{
		filepath.Join(cacheDirectory, "cache.bin"),
		filepath.Join(tempDirectory, "temp.bin"),
		filepath.Join(diagnosticsDirectory, "log.tracev3"),
		filepath.Join(uuidTextDirectory, "symbols"),
		filepath.Join(linguisticDirectory, "language-model.bin"),
	} {
		if _, err := os.Lstat(removed); !os.IsNotExist(err) {
			t.Errorf("cleanup left %s", removed)
		}
	}
	for _, preservedDirectory := range []string{
		cacheDirectory,
		tempDirectory,
		diagnosticsDirectory,
		uuidTextDirectory,
		linguisticDirectory,
	} {
		if info, err := os.Lstat(preservedDirectory); err != nil || !info.IsDir() {
			t.Errorf("cleanup must preserve directory %s", preservedDirectory)
		}
	}
	for _, preserved := range []string{
		filepath.Join(requiredSiriDirectory, "model.bin"),
		filepath.Join(unrelatedAssetDirectory, "trust.bin"),
		filepath.Join(appDocumentDirectory, "user.db"),
		userNamedCache,
		userNamedLogs,
		userNamedTemp,
		assetNamedCache,
	} {
		if _, err := os.Lstat(preserved); err != nil {
			t.Errorf("cleanup touched non-cleanable data %s: %v", preserved, err)
		}
	}
}

func TestDiskCleanupRejectsIntermediateSymlink(t *testing.T) {
	root := t.TempDir()
	dataDirectory := filepath.Join(root, "data")
	outsideLogDirectory := filepath.Join(root, "outside", "log")
	outsideFile := filepath.Join(outsideLogDirectory, "keep.log")
	writeTestFile(t, outsideFile, 4096)
	if err := os.MkdirAll(dataDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Dir(outsideLogDirectory), filepath.Join(dataDirectory, "var")); err != nil {
		t.Fatal(err)
	}

	if _, err := cleanDiskAt("TEST-UDID", dataDirectory, []string{"logs"}); err == nil {
		t.Fatal("cleanup should reject a target reached through an intermediate symlink")
	}
	if _, err := os.Lstat(outsideFile); err != nil {
		t.Fatalf("cleanup touched data outside the simulator root: %v", err)
	}
}

func TestDiskCleanupDoesNotFollowSymlinks(t *testing.T) {
	root := t.TempDir()
	dataDirectory := filepath.Join(root, "data")
	cacheDirectory := filepath.Join(dataDirectory, "Library", "Caches")
	outsideDirectory := filepath.Join(root, "outside")
	outsideFile := filepath.Join(outsideDirectory, "keep.txt")
	writeTestFile(t, outsideFile, 4096)
	if err := os.MkdirAll(cacheDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsideDirectory, filepath.Join(cacheDirectory, "outside-link")); err != nil {
		t.Fatal(err)
	}

	if _, err := cleanDiskAt("TEST-UDID", dataDirectory, []string{"caches"}); err != nil {
		t.Fatalf("cleanDiskAt() error = %v", err)
	}
	if _, err := os.Lstat(outsideFile); err != nil {
		t.Fatalf("cleanup followed a symlink outside simulator data: %v", err)
	}
}

func TestDiskCleanupRejectsUnsafeTargetsAndMeasuredOnlyCategory(t *testing.T) {
	root := t.TempDir()
	dataDirectory := filepath.Join(root, "data")
	if err := os.MkdirAll(dataDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := requireDescendant(dataDirectory, dataDirectory); err == nil {
		t.Error("requireDescendant should reject the data root itself")
	}
	if err := requireDescendant(dataDirectory, root); err == nil {
		t.Error("requireDescendant should reject a parent directory")
	}
	if _, err := validateDiskCleanupSelection([]string{"required-siri-assets"}); err == nil {
		t.Error("measured-only MobileAsset cleanup must be rejected")
	}
}

func writeTestFile(t *testing.T, target string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(target, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
}
