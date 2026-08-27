package simslim

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	testSourceUDID = "11111111-1111-1111-1111-111111111111"
	testCloneUDID  = "22222222-2222-2222-2222-222222222222"
)

func TestDesiredCloneDisabledKeepsOnlySlimmableServices(t *testing.T) {
	var slimmable, anotherSlimmable, required string
	for _, category := range Categories {
		if slimmable == "" && len(category.Labels) > 1 {
			slimmable = category.Labels[0]
			anotherSlimmable = category.Labels[1]
		}
		if required == "" && len(category.AlwaysEnabled) > 0 {
			required = category.AlwaysEnabled[0].Label
		}
	}
	if slimmable == "" || required == "" {
		t.Fatal("test requires both slimmable and always-enabled profile entries")
	}
	disabled := map[string]bool{
		slimmable:                    true,
		anotherSlimmable:             false,
		required:                     true,
		"com.example.unmanaged-test": true,
	}

	got := desiredCloneDisabled(disabled)
	if len(got) != 1 || !got[slimmable] {
		t.Fatalf("desiredCloneDisabled() = %v, want only %q", got, slimmable)
	}
}

func TestSanitizeClonedDeviceAtRebasesDirectLinks(t *testing.T) {
	paths := newTestCloneFilesystem(t)

	trialSource := filepath.Join(paths.sourceDataDirectory, "Library", "Trial", "shared-state")
	trialClone := filepath.Join(paths.cloneDataDirectory, "Library", "Trial", "shared-state")
	writeCloneTestFile(t, trialSource, "source trial state")
	writeCloneTestFile(t, trialClone, "cloned trial state")
	absoluteLink := filepath.Join(paths.cloneDataDirectory, "Library", "Trial", "current-state")
	mustMkdirAll(t, filepath.Dir(absoluteLink))
	if err := os.Symlink(trialSource, absoluteLink); err != nil {
		t.Fatal(err)
	}

	shortcutSource := filepath.Join(paths.sourceDataDirectory, "Library", "Shortcuts", "store")
	shortcutClone := filepath.Join(paths.cloneDataDirectory, "Library", "Shortcuts", "store")
	writeCloneTestFile(t, shortcutSource, "source shortcuts")
	writeCloneTestFile(t, shortcutClone, "cloned shortcuts")
	relativeSourceLink := filepath.Join(paths.cloneDataDirectory, "Library", "Shortcuts", "source-relative")
	relativeSourceTarget, err := filepath.Rel(filepath.Dir(relativeSourceLink), shortcutSource)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(relativeSourceTarget, relativeSourceLink); err != nil {
		t.Fatal(err)
	}

	localRelativeLink := filepath.Join(paths.cloneDataDirectory, "Library", "Trial", "local-relative")
	if err := os.Symlink("shared-state", localRelativeLink); err != nil {
		t.Fatal(err)
	}
	sharedRuntimeLink := filepath.Join(paths.cloneDataDirectory, "Library", "shared-runtime")
	const sharedRuntimeTarget = "/Library/Developer/CoreSimulator/Volumes/iOS_23A123"
	if err := os.Symlink(sharedRuntimeTarget, sharedRuntimeLink); err != nil {
		t.Fatal(err)
	}
	logsLink := filepath.Join(paths.cloneDataDirectory, "Library", "Logs")
	if err := os.Symlink(paths.sourceLogDirectory, logsLink); err != nil {
		t.Fatal(err)
	}

	lsdDirectory := filepath.Join(paths.cloneDataDirectory, "var", "db", "lsd")
	writeCloneTestFile(t, filepath.Join(lsdDirectory, "com.apple.LaunchServices-1-v2.csstore"), "stale paths")
	writeCloneTestFile(t, filepath.Join(lsdDirectory, "SystemDataOnly-com.apple.LaunchServices-1-v2.csstore"), "keep")
	frontBoardDirectory := filepath.Join(paths.cloneDataDirectory, "Library", "FrontBoard")
	for _, name := range []string{"applicationState.db", "applicationState.db-shm", "applicationState.db-wal"} {
		writeCloneTestFile(t, filepath.Join(frontBoardDirectory, name), "stale paths")
	}
	generatedStateDirectories := []string{
		filepath.Join(paths.cloneDataDirectory, "Library", "AppleMediaServices", "Engagement", "internal", "database"),
		filepath.Join(paths.cloneDataDirectory, "Library", "Spotlight"),
		filepath.Join(paths.cloneDataDirectory, "Library", "chronod", "replicator"),
		filepath.Join(paths.cloneDataDirectory, "Library", "com.apple.nsurlsessiond"),
		filepath.Join(paths.cloneDataDirectory, "private", "var", "MobileAsset", "AssetsV2", "locks"),
		filepath.Join(paths.cloneDataDirectory, "private", "var", "MobileAsset", "AssetsV2", "persisted"),
		filepath.Join(paths.cloneDataDirectory, "private", "var", "db", "assetsubscriptiond", "history"),
		filepath.Join(paths.cloneDataDirectory, "var", "db", "diagnostics", "Persist"),
		filepath.Join(paths.cloneDataDirectory, "var", "db", "diagnostics", "Special"),
		filepath.Join(paths.cloneDataDirectory, "Containers", "Shared", "AppGroup", "SYSTEM", "replicatord"),
	}
	for _, directory := range generatedStateDirectories {
		writeCloneTestFile(t, filepath.Join(directory, "copied-state.db"), "file://"+trialSource)
	}
	downloadedAsset := filepath.Join(
		paths.cloneDataDirectory,
		"private",
		"var",
		"MobileAsset",
		"AssetsV2",
		"com_apple_MobileAsset_Test",
		"AssetData",
		"model.bin",
	)
	writeCloneTestFile(t, downloadedAsset, "downloaded payload")

	writeCloneTestFile(t, filepath.Join(paths.cloneDataDirectory, "Library", "Caches", "system.cache"), "discard")
	writeCloneTestFile(t, filepath.Join(paths.cloneDataDirectory, "tmp", "snapshot"), "discard")
	springBoardPreference := filepath.Join(
		paths.cloneDataDirectory,
		"Library",
		"Preferences",
		"com.apple.springboard.plist",
	)
	writeCloneTestFile(
		t,
		springBoardPreference,
		"file://"+filepath.Join(paths.sourceDataDirectory, "Library", "Poster", "snapshot.atx"),
	)
	appBundle := filepath.Join(paths.cloneDataDirectory, "Containers", "Bundle", "Application", "APP", "FleetDog.app", "FleetDog")
	appDocument := filepath.Join(paths.cloneDataDirectory, "Containers", "Data", "Application", "APP", "Documents", "fleetdog.db")
	appCache := filepath.Join(paths.cloneDataDirectory, "Containers", "Data", "Application", "APP", "Library", "Caches", "offline.cache")
	writeCloneTestFile(t, appBundle, "executable")
	writeCloneTestFile(t, appDocument, "user data")
	writeCloneTestFile(t, appCache, "app cache")

	if err := sanitizeClonedDeviceAt(paths); err != nil {
		t.Fatalf("sanitizeClonedDeviceAt() error = %v", err)
	}

	assertSymlinkTarget(t, absoluteLink, trialClone)
	wantRelativeCloneTarget, err := filepath.Rel(filepath.Dir(relativeSourceLink), shortcutClone)
	if err != nil {
		t.Fatal(err)
	}
	assertSymlinkTarget(t, relativeSourceLink, wantRelativeCloneTarget)
	assertSymlinkTarget(t, localRelativeLink, "shared-state")
	assertSymlinkTarget(t, sharedRuntimeLink, sharedRuntimeTarget)
	assertSymlinkTarget(t, logsLink, paths.cloneLogDirectory)

	assertMissing(t, filepath.Join(lsdDirectory, "com.apple.LaunchServices-1-v2.csstore"))
	assertExists(t, filepath.Join(lsdDirectory, "SystemDataOnly-com.apple.LaunchServices-1-v2.csstore"))
	for _, name := range []string{"applicationState.db", "applicationState.db-shm", "applicationState.db-wal"} {
		assertMissing(t, filepath.Join(frontBoardDirectory, name))
	}
	for _, directory := range generatedStateDirectories {
		assertDirectoryEmpty(t, directory)
	}
	assertExists(t, downloadedAsset)
	assertDirectoryEmpty(t, filepath.Join(paths.cloneDataDirectory, "Library", "Caches"))
	assertDirectoryEmpty(t, filepath.Join(paths.cloneDataDirectory, "tmp"))
	preferenceContents, err := os.ReadFile(springBoardPreference)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(preferenceContents), testSourceUDID) ||
		!strings.Contains(string(preferenceContents), testCloneUDID) {
		t.Errorf("rebased preference = %q, want only clone UDID", preferenceContents)
	}
	assertExists(t, appBundle)
	assertExists(t, appDocument)
	assertExists(t, appCache)

	err = filepath.WalkDir(paths.cloneDeviceDirectory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink == 0 {
			return nil
		}
		target, readErr := os.Readlink(path)
		if readErr != nil {
			return readErr
		}
		if strings.Contains(target, testSourceUDID) {
			t.Errorf("clone symlink %s still names source UDID in %q", path, target)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestSimulatorProcessIDsFromPS(t *testing.T) {
	output := strings.Join([]string{
		"100 launchd_sim SIMULATOR_UDID=" + testCloneUDID + " HOME=/clone",
		"101 SpringBoard HOME=/clone SIMULATOR_UDID=" + testCloneUDID,
		"102 source SIMULATOR_UDID=" + testSourceUDID,
		"not-a-pid helper SIMULATOR_UDID=" + testCloneUDID,
		"",
	}, "\n")
	got := simulatorProcessIDsFromPS(output, testCloneUDID)
	if len(got) != 2 || got[0] != 100 || got[1] != 101 {
		t.Fatalf("simulatorProcessIDsFromPS() = %v, want [100 101]", got)
	}
}

func TestSourceReferencesFromLsof(t *testing.T) {
	paths := newTestCloneFilesystem(t)
	output := strings.Join([]string{
		"p100",
		"fcwd",
		"n" + paths.cloneDataDirectory,
		"ftxt",
		"n" + filepath.Join(paths.sourceDataDirectory, "Library", "Poster", "snapshot.atx"),
		"p101",
		"ftxt",
		"n/Library/Developer/CoreSimulator/Volumes/iOS_Runtime",
		"",
	}, "\n")
	got := sourceReferencesFromLsof(output, paths)
	if len(got) != 1 || got[0].pid != 100 || !strings.Contains(got[0].path, testSourceUDID) {
		t.Fatalf("sourceReferencesFromLsof() = %v, want one PID 100 source path", got)
	}
}

func TestEvaluateCloneLsofAuditAcceptsLiveRecordsWhenAnotherPIDExited(t *testing.T) {
	paths := newTestCloneFilesystem(t)
	output := strings.Join([]string{
		"p100",
		"fcwd",
		"n" + paths.cloneDataDirectory,
		"",
	}, "\n")

	complete, err := evaluateCloneLsofAudit(output, errors.New("exit status 1"), paths)
	if !complete || err != nil {
		t.Fatalf("evaluateCloneLsofAudit() = (%t, %v), want complete success", complete, err)
	}
}

func TestEvaluateCloneLsofAuditRetriesWhenAllSnapshottedPIDsExited(t *testing.T) {
	paths := newTestCloneFilesystem(t)
	complete, err := evaluateCloneLsofAudit("", errors.New("exit status 1"), paths)
	if complete || err == nil {
		t.Fatalf("evaluateCloneLsofAudit() = (%t, %v), want incomplete error", complete, err)
	}
}

func TestEvaluateCloneLsofAuditRejectsSourceReferenceDespiteExitError(t *testing.T) {
	paths := newTestCloneFilesystem(t)
	output := strings.Join([]string{
		"p100",
		"fcwd",
		"n" + filepath.Join(paths.sourceDataDirectory, "Library", "linked.db"),
		"",
	}, "\n")

	complete, err := evaluateCloneLsofAudit(output, errors.New("exit status 1"), paths)
	if !complete || err == nil || !strings.Contains(err.Error(), "source simulator path") {
		t.Fatalf("evaluateCloneLsofAudit() = (%t, %v), want complete source-path error", complete, err)
	}
}

func TestSanitizeClonedDeviceAtRejectsUnknownSourceSymlink(t *testing.T) {
	paths := newTestCloneFilesystem(t)
	link := filepath.Join(paths.cloneDataDirectory, "Library", "unexpected-source-link")
	if err := os.Symlink(filepath.Join(t.TempDir(), testSourceUDID, "state"), link); err != nil {
		t.Fatal(err)
	}

	err := sanitizeClonedDeviceAt(paths)
	if err == nil || !strings.Contains(err.Error(), "source simulator") {
		t.Fatalf("sanitizeClonedDeviceAt() error = %v, want unknown source-link rejection", err)
	}
}

func TestSanitizeClonedDeviceAtRejectsHardLinkedSourceFile(t *testing.T) {
	paths := newTestCloneFilesystem(t)
	source := filepath.Join(paths.sourceDataDirectory, "Library", "State", "shared.db")
	clone := filepath.Join(paths.cloneDataDirectory, "Library", "State", "shared.db")
	writeCloneTestFile(t, source, "shared inode")
	mustMkdirAll(t, filepath.Dir(clone))
	if err := os.Link(source, clone); err != nil {
		t.Fatal(err)
	}

	err := sanitizeClonedDeviceAt(paths)
	if err == nil || !strings.Contains(err.Error(), "hard-linked") {
		t.Fatalf("sanitizeClonedDeviceAt() error = %v, want hard-link rejection", err)
	}
}

func newTestCloneFilesystem(t *testing.T) cloneFilesystem {
	t.Helper()
	root := t.TempDir()
	paths := cloneFilesystem{
		sourceUDID:            testSourceUDID,
		cloneUDID:             testCloneUDID,
		sourceDeviceDirectory: filepath.Join(root, "Devices", testSourceUDID),
		cloneDeviceDirectory:  filepath.Join(root, "Devices", testCloneUDID),
		sourceLogDirectory:    filepath.Join(root, "Logs", testSourceUDID),
		cloneLogDirectory:     filepath.Join(root, "Logs", testCloneUDID),
	}
	paths.sourceDataDirectory = filepath.Join(paths.sourceDeviceDirectory, "data")
	paths.cloneDataDirectory = filepath.Join(paths.cloneDeviceDirectory, "data")
	mustMkdirAll(t, filepath.Join(paths.sourceDataDirectory, "Library"))
	mustMkdirAll(t, filepath.Join(paths.cloneDataDirectory, "Library"))
	return paths
}

func writeCloneTestFile(t *testing.T, path, contents string) {
	t.Helper()
	mustMkdirAll(t, filepath.Dir(path))
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatal(err)
	}
}

func mustMkdirAll(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func assertSymlinkTarget(t *testing.T, path, want string) {
	t.Helper()
	got, err := os.Readlink(path)
	if err != nil {
		t.Fatalf("readlink %s: %v", path, err)
	}
	if got != want {
		t.Errorf("readlink %s = %q, want %q", path, got, want)
	}
}

func assertExists(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err != nil {
		t.Errorf("expected %s to exist: %v", path, err)
	}
}

func assertMissing(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Errorf("expected %s to be absent; lstat error = %v", path, err)
	}
}

func assertDirectoryEmpty(t *testing.T, path string) {
	t.Helper()
	entries, err := os.ReadDir(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	if len(entries) != 0 {
		t.Errorf("directory %s contains %v, want empty", path, entries)
	}
}
