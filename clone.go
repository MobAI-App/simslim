package simslim

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

type cloneFilesystem struct {
	sourceUDID            string
	cloneUDID             string
	sourceDeviceDirectory string
	cloneDeviceDirectory  string
	sourceDataDirectory   string
	cloneDataDirectory    string
	sourceLogDirectory    string
	cloneLogDirectory     string
}

// desiredCloneDisabled copies only labels SimSlim is allowed to disable. A
// source may contain unrelated or obsolete launchd overrides; cloning must not
// turn those into new SimSlim-managed state or propagate an unsafe override.
func desiredCloneDisabled(disabled map[string]bool) map[string]bool {
	slimmable := SlimmableSet()
	desired := make(map[string]bool)
	for label, isDisabled := range disabled {
		if isDisabled && slimmable[label] {
			desired[label] = true
		}
	}
	return desired
}

// CloneDevice prepares a point-in-time copy. CoreSimulator's raw clone carries
// absolute source paths in symlinks and generated registries, so the source
// remains shut down until direct links have been rebased, app registrations
// have been rebuilt, the copied SimSlim service profile has been verified, and
// the running clone has been audited for open source paths. Any preparation
// failure deletes the clone rather than returning it as ready.
func CloneDevice(ctx context.Context, udid, name string) (newUDID string, err error) {
	name, err = NormalizeSimulatorName(name)
	if err != nil {
		return "", err
	}

	source, sourceDataDirectory, err := simulatorDataDirectory(ctx, udid)
	if err != nil {
		return "", err
	}
	if source.State != "Booted" && source.State != "Shutdown" {
		return "", fmt.Errorf("simulator must be booted or shutdown before cloning (it is %s)", source.State)
	}
	sourceWasBooted := source.State == "Booted"
	defer func() {
		restoreCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), BootTimeout)
		defer cancel()
		if restoreErr := restoreCloneSourceState(restoreCtx, source.Set, udid, sourceWasBooted); restoreErr != nil {
			switch {
			case err != nil:
				err = fmt.Errorf("%v; additionally could not restore the source boot state: %w", err, restoreErr)
			case newUDID != "":
				err = fmt.Errorf("cloned simulator %s, but could not restore the source boot state: %w", newUDID, restoreErr)
			default:
				err = fmt.Errorf("could not restore the source boot state: %w", restoreErr)
			}
		}
	}()

	// launchctl state can only be read from a fully booted device. A shutdown
	// source is booted temporarily, then both source states converge here before
	// CoreSimulator copies its files.
	if err := BootAndWait(ctx, source.Set, udid); err != nil {
		return "", fmt.Errorf("boot source to capture its service profile: %w", err)
	}
	disabled, err := readDisabled(ctx, source.Set, udid)
	if err != nil {
		return "", fmt.Errorf("capture source service profile: %w", err)
	}
	desired := desiredCloneDisabled(disabled)
	if err := Shutdown(ctx, source.Set, udid); err != nil {
		return "", fmt.Errorf("shutdown source before cloning: %w", err)
	}
	if err := WaitShutdown(ctx, source.Set, udid, ShutdownTimeout); err != nil {
		return "", fmt.Errorf("wait for source shutdown before cloning: %w", err)
	}

	out, err := xcrun(ctx, simctlArgs(source.Set, "clone", udid, name)...)
	if err != nil {
		return "", err
	}
	createdUDID, err := parseClonedUDID(out)
	if err != nil {
		return "", err
	}
	newUDID = createdUDID
	cloneIsSafe := false
	defer func() {
		if cloneIsSafe {
			return
		}
		newUDID = ""
		cleanupErr := deleteUnsafeClone(ctx, source.Set, createdUDID)
		if cleanupErr != nil {
			err = fmt.Errorf(
				"prepare cloned simulator %s: %w; additionally could not delete the unsafe clone: %v",
				createdUDID,
				err,
				cleanupErr,
			)
			return
		}
		err = fmt.Errorf("prepare cloned simulator %s: %w; deleted the unsafe clone", createdUDID, err)
	}()

	paths, err := cloneFilesystemFor(ctx, source, sourceDataDirectory, createdUDID)
	if err != nil {
		return "", err
	}
	if err := sanitizeClonedDeviceAt(paths); err != nil {
		return "", err
	}

	// Enforce the captured state instead of trusting a copied launchd database.
	// ensure also clears any required-to-run label that happened to be disabled
	// in the source, and verifies persistence across a reboot when it changes.
	if _, err := ensure(ctx, source.Set, createdUDID, desired, nil); err != nil {
		return "", fmt.Errorf("restore cloned service profile: %w", err)
	}
	if err := verifyRunningCloneDoesNotOpenSource(ctx, paths); err != nil {
		return "", err
	}
	if err := Shutdown(ctx, source.Set, createdUDID); err != nil {
		return "", fmt.Errorf("shutdown prepared clone: %w", err)
	}
	if err := WaitShutdown(ctx, source.Set, createdUDID, ShutdownTimeout); err != nil {
		return "", fmt.Errorf("wait for prepared clone shutdown: %w", err)
	}
	if err := verifyCloneIndependence(paths); err != nil {
		return "", err
	}

	cloneIsSafe = true
	return createdUDID, nil
}

// RepairClonedDevice removes direct filesystem links and open paths into the
// supplied source from a clone made by an older SimSlim version. CoreSimulator
// does not expose clone lineage, so callers must supply the actual source UDID.
// It preserves the target's apps, app data, settings, SimSlim profile, and
// original boot state. A failed repair leaves the target shutdown.
func RepairClonedDevice(ctx context.Context, sourceUDID, cloneUDID string) (err error) {
	if sourceUDID == cloneUDID {
		return fmt.Errorf("clone source and destination UDIDs must be distinct")
	}
	source, sourceDataDirectory, err := simulatorDataDirectory(ctx, sourceUDID)
	if err != nil {
		return err
	}
	clone, _, err := simulatorDataDirectory(ctx, cloneUDID)
	if err != nil {
		return err
	}
	if source.Set != clone.Set {
		return fmt.Errorf("source and clone must belong to the same simulator set")
	}
	if source.OSVersion != clone.OSVersion {
		return fmt.Errorf(
			"source and clone runtimes differ (iOS %s and iOS %s)",
			source.OSVersion,
			clone.OSVersion,
		)
	}
	for _, device := range []Device{source, clone} {
		if device.State != "Booted" && device.State != "Shutdown" {
			return fmt.Errorf(
				"simulator %s must be booted or shutdown before repair (it is %s)",
				device.UDID,
				device.State,
			)
		}
	}
	paths, err := cloneFilesystemFor(ctx, source, sourceDataDirectory, cloneUDID)
	if err != nil {
		return err
	}

	sourceWasBooted := source.State == "Booted"
	cloneWasBooted := clone.State == "Booted"
	defer func() {
		restoreCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), BootTimeout)
		defer cancel()
		if restoreErr := restoreCloneSourceState(restoreCtx, source.Set, sourceUDID, sourceWasBooted); restoreErr != nil {
			if err != nil {
				err = fmt.Errorf("%v; additionally could not restore the source boot state: %w", err, restoreErr)
			} else {
				err = fmt.Errorf("clone repaired, but could not restore the source boot state: %w", restoreErr)
			}
		}
	}()

	repairIsSafe := false
	defer func() {
		if repairIsSafe {
			return
		}
		shutdownCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), BootTimeout)
		defer cancel()
		if shutdownErr := restoreCloneSourceState(shutdownCtx, clone.Set, cloneUDID, false); shutdownErr != nil {
			if err != nil {
				err = fmt.Errorf("%v; additionally could not leave the clone safely shutdown: %w", err, shutdownErr)
			} else {
				err = fmt.Errorf("could not leave the clone safely shutdown: %w", shutdownErr)
			}
		}
	}()

	// Stop a running legacy clone first so it cannot keep writing through a
	// source-bound symlink while the source shuts down. Both devices must be
	// offline before any copied filesystem state is rebuilt.
	if err := restoreCloneSourceState(ctx, clone.Set, cloneUDID, false); err != nil {
		return fmt.Errorf("shutdown clone before repair: %w", err)
	}
	if err := restoreCloneSourceState(ctx, source.Set, sourceUDID, false); err != nil {
		return fmt.Errorf("shutdown source before clone repair: %w", err)
	}

	// Sanitization does not clear or replace launchd's override database. Do it
	// before the first repair-initiated boot so a shutdown legacy clone can never
	// start with a Library symlink that still resolves into the source device.
	if err := sanitizeClonedDeviceAt(paths); err != nil {
		return err
	}
	if err := BootAndWait(ctx, clone.Set, cloneUDID); err != nil {
		return fmt.Errorf("boot clone to capture its service profile: %w", err)
	}
	disabled, err := readDisabled(ctx, clone.Set, cloneUDID)
	if err != nil {
		return fmt.Errorf("capture cloned service profile: %w", err)
	}
	desired := desiredCloneDisabled(disabled)
	if _, err := ensure(ctx, clone.Set, cloneUDID, desired, nil); err != nil {
		return fmt.Errorf("restore repaired clone service profile: %w", err)
	}
	if err := verifyRunningCloneDoesNotOpenSource(ctx, paths); err != nil {
		return err
	}
	if !cloneWasBooted {
		if err := restoreCloneSourceState(ctx, clone.Set, cloneUDID, false); err != nil {
			return fmt.Errorf("restore clone shutdown state: %w", err)
		}
	}

	repairIsSafe = true
	return nil
}

func restoreCloneSourceState(ctx context.Context, set, udid string, shouldBeBooted bool) error {
	device, err := FindDevice(ctx, udid, set)
	if err != nil {
		return err
	}
	if shouldBeBooted {
		if device.State == "Booted" {
			return nil
		}
		return BootAndWait(ctx, set, udid)
	}
	if device.State == "Shutdown" {
		return nil
	}
	if err := Shutdown(ctx, set, udid); err != nil {
		return err
	}
	return WaitShutdown(ctx, set, udid, ShutdownTimeout)
}

func deleteUnsafeClone(parent context.Context, set, udid string) error {
	cleanupCtx, cancel := context.WithTimeout(context.WithoutCancel(parent), BootTimeout)
	defer cancel()

	var stopErr error
	if err := Shutdown(cleanupCtx, set, udid); err != nil {
		stopErr = err
	} else if err := WaitShutdown(cleanupCtx, set, udid, ShutdownTimeout); err != nil {
		stopErr = err
	}
	_, deleteErr := xcrun(cleanupCtx, simctlArgs(set, "delete", udid)...)
	if deleteErr == nil {
		return nil
	}
	if stopErr != nil {
		return fmt.Errorf("stop clone: %v; delete clone: %w", stopErr, deleteErr)
	}
	return deleteErr
}

func cloneFilesystemFor(
	ctx context.Context,
	source Device,
	sourceDataDirectory string,
	cloneUDID string,
) (cloneFilesystem, error) {
	clone, cloneDataDirectory, err := simulatorDataDirectory(ctx, cloneUDID)
	if err != nil {
		return cloneFilesystem{}, err
	}
	if clone.Set != source.Set {
		return cloneFilesystem{}, fmt.Errorf(
			"CoreSimulator placed clone %s in %s instead of source set %s",
			cloneUDID,
			clone.Set,
			source.Set,
		)
	}
	homeDirectory, err := os.UserHomeDir()
	if err != nil {
		return cloneFilesystem{}, fmt.Errorf("locate CoreSimulator logs: %w", err)
	}
	logsRoot := filepath.Join(homeDirectory, "Library", "Logs", "CoreSimulator")
	return cloneFilesystem{
		sourceUDID:            source.UDID,
		cloneUDID:             cloneUDID,
		sourceDeviceDirectory: filepath.Dir(sourceDataDirectory),
		cloneDeviceDirectory:  filepath.Dir(cloneDataDirectory),
		sourceDataDirectory:   sourceDataDirectory,
		cloneDataDirectory:    cloneDataDirectory,
		sourceLogDirectory:    filepath.Join(logsRoot, source.UDID),
		cloneLogDirectory:     filepath.Join(logsRoot, cloneUDID),
	}, nil
}

func sanitizeClonedDeviceAt(paths cloneFilesystem) error {
	if err := validateCloneFilesystem(paths); err != nil {
		return err
	}

	// These stores are generated from installed apps and current simulator
	// paths. Regenerating only the system copies preserves app bundles, app data,
	// settings, and even app-owned caches while removing stale absolute paths.
	if err := resetClonedLaunchServicesAt(paths.cloneDataDirectory); err != nil {
		return err
	}
	if err := resetClonedFrontBoardAt(paths.cloneDataDirectory); err != nil {
		return err
	}
	if err := resetClonedGeneratedPathStateAt(paths.cloneDataDirectory); err != nil {
		return err
	}
	for _, directory := range []string{
		filepath.Join(paths.cloneDataDirectory, "Library", "Caches"),
		filepath.Join(paths.cloneDataDirectory, "tmp"),
	} {
		if err := clearDirectoryContents(paths.cloneDataDirectory, directory); err != nil {
			return fmt.Errorf("reset cloned transient state: %w", err)
		}
	}
	if err := rebaseClonePropertyLists(paths); err != nil {
		return err
	}

	if err := rebaseCloneSymlinks(paths); err != nil {
		return err
	}
	return verifyCloneIndependence(paths)
}

// Property lists frequently persist simulator-local file URLs (wallpaper is a
// notable example). UUIDs have equal byte lengths, so replacing one UUID with
// the other preserves both XML and binary plist structure while retaining the
// actual setting and redirecting its file URL into the clone.
func rebaseClonePropertyLists(paths cloneFilesystem) error {
	if len(paths.sourceUDID) != len(paths.cloneUDID) {
		return fmt.Errorf("source and clone UDIDs must have equal lengths")
	}
	source := []byte(paths.sourceUDID)
	clone := []byte(paths.cloneUDID)
	return filepath.WalkDir(paths.cloneDeviceDirectory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if !entry.Type().IsRegular() || !strings.EqualFold(filepath.Ext(path), ".plist") {
			return nil
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read cloned property list %s: %w", path, err)
		}
		if !bytes.Contains(contents, source) {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return fmt.Errorf("inspect cloned property list %s: %w", path, err)
		}
		contents = bytes.ReplaceAll(contents, source, clone)
		if err := replaceRegularFile(path, contents, info.Mode()); err != nil {
			return fmt.Errorf("rebase cloned property list %s: %w", path, err)
		}
		return nil
	})
}

func replaceRegularFile(path string, contents []byte, mode os.FileMode) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".simslim-rebase-")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer func() { _ = os.Remove(temporaryPath) }()
	if err := temporary.Chmod(mode.Perm()); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(contents); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, path)
}

func validateCloneFilesystem(paths cloneFilesystem) error {
	if paths.sourceUDID == "" || paths.cloneUDID == "" || paths.sourceUDID == paths.cloneUDID {
		return fmt.Errorf("clone source and destination UDIDs must be distinct")
	}
	for label, directory := range map[string]string{
		"source device": paths.sourceDeviceDirectory,
		"clone device":  paths.cloneDeviceDirectory,
		"source data":   paths.sourceDataDirectory,
		"clone data":    paths.cloneDataDirectory,
	} {
		info, err := os.Lstat(directory)
		if err != nil {
			return fmt.Errorf("locate %s directory: %w", label, err)
		}
		if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("%s path is not a real directory: %s", label, directory)
		}
	}
	for deviceDirectory, dataDirectory := range map[string]string{
		paths.sourceDeviceDirectory: paths.sourceDataDirectory,
		paths.cloneDeviceDirectory:  paths.cloneDataDirectory,
	} {
		if err := requireDescendant(deviceDirectory, dataDirectory); err != nil {
			return err
		}
		if err := requireResolvedDescendant(deviceDirectory, dataDirectory); err != nil {
			return err
		}
	}
	return nil
}

func resetClonedLaunchServicesAt(dataDirectory string) error {
	lsdDirectory := filepath.Join(dataDirectory, "var", "db", "lsd")
	if err := requireDescendant(dataDirectory, lsdDirectory); err != nil {
		return err
	}
	info, err := os.Lstat(lsdDirectory)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("locate cloned LaunchServices data: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("cloned LaunchServices path is not a real directory: %s", lsdDirectory)
	}
	if err := requireResolvedDescendant(dataDirectory, lsdDirectory); err != nil {
		return err
	}

	entries, err := os.ReadDir(lsdDirectory)
	if err != nil {
		return fmt.Errorf("read cloned LaunchServices data: %w", err)
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, "com.apple.LaunchServices-") || !strings.Contains(name, ".csstore") {
			continue
		}

		target := filepath.Join(lsdDirectory, name)
		if err := requireDescendant(lsdDirectory, target); err != nil {
			return err
		}
		targetInfo, err := os.Lstat(target)
		if err != nil {
			return fmt.Errorf("inspect cloned LaunchServices store: %w", err)
		}
		if !targetInfo.Mode().IsRegular() || targetInfo.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("cloned LaunchServices store is not a regular file: %s", target)
		}
		if err := os.Remove(target); err != nil {
			return fmt.Errorf("reset cloned LaunchServices store: %w", err)
		}
	}
	return nil
}

func resetClonedFrontBoardAt(dataDirectory string) error {
	frontBoardDirectory := filepath.Join(dataDirectory, "Library", "FrontBoard")
	if err := requireDescendant(dataDirectory, frontBoardDirectory); err != nil {
		return err
	}
	info, err := os.Lstat(frontBoardDirectory)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("locate cloned FrontBoard data: %w", err)
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("cloned FrontBoard path is not a real directory: %s", frontBoardDirectory)
	}
	if err := requireResolvedDescendant(dataDirectory, frontBoardDirectory); err != nil {
		return err
	}
	for _, name := range []string{"applicationState.db", "applicationState.db-shm", "applicationState.db-wal"} {
		target := filepath.Join(frontBoardDirectory, name)
		targetInfo, err := os.Lstat(target)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("inspect cloned FrontBoard store: %w", err)
		}
		if !targetInfo.Mode().IsRegular() || targetInfo.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("cloned FrontBoard store is not a regular file: %s", target)
		}
		if err := os.Remove(target); err != nil {
			return fmt.Errorf("reset cloned FrontBoard store: %w", err)
		}
	}
	return nil
}

// resetClonedGeneratedPathStateAt clears system-owned indexes, task databases,
// and asset registries that persist absolute simulator paths outside plists.
// These stores are regenerated by their daemons; installed apps, app data, and
// downloaded MobileAsset payloads are deliberately outside this allowlist.
func resetClonedGeneratedPathStateAt(dataDirectory string) error {
	directories := []string{
		filepath.Join(dataDirectory, "Library", "AppleMediaServices", "Engagement", "internal", "database"),
		filepath.Join(dataDirectory, "Library", "Spotlight"),
		filepath.Join(dataDirectory, "Library", "chronod", "replicator"),
		filepath.Join(dataDirectory, "Library", "com.apple.nsurlsessiond"),
		filepath.Join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "locks"),
		filepath.Join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2", "persisted"),
		filepath.Join(dataDirectory, "private", "var", "db", "assetsubscriptiond", "history"),
		filepath.Join(dataDirectory, "var", "db", "diagnostics", "Persist"),
		filepath.Join(dataDirectory, "var", "db", "diagnostics", "Special"),
	}
	replicatorDirectories, err := filepath.Glob(
		filepath.Join(dataDirectory, "Containers", "Shared", "AppGroup", "*", "replicatord"),
	)
	if err != nil {
		return fmt.Errorf("locate cloned replicator state: %w", err)
	}
	directories = append(directories, replicatorDirectories...)

	for _, directory := range directories {
		if err := clearDirectoryContents(dataDirectory, directory); err != nil {
			return fmt.Errorf("reset cloned generated path state %s: %w", directory, err)
		}
	}
	return nil
}

func rebaseCloneSymlinks(paths cloneFilesystem) error {
	return filepath.WalkDir(paths.cloneDeviceDirectory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink == 0 {
			return nil
		}
		target, err := os.Readlink(path)
		if err != nil {
			return fmt.Errorf("read cloned symlink %s: %w", path, err)
		}
		resolvedTarget := target
		if !filepath.IsAbs(resolvedTarget) {
			resolvedTarget = filepath.Join(filepath.Dir(path), resolvedTarget)
		}
		resolvedTarget = filepath.Clean(resolvedTarget)

		mappedTarget, mapped := rebasePath(
			resolvedTarget,
			paths.sourceDeviceDirectory,
			paths.cloneDeviceDirectory,
		)
		if !mapped {
			mappedTarget, mapped = rebasePath(
				resolvedTarget,
				paths.sourceLogDirectory,
				paths.cloneLogDirectory,
			)
		}
		if !mapped {
			return nil
		}

		newTarget := mappedTarget
		if !filepath.IsAbs(target) {
			newTarget, err = filepath.Rel(filepath.Dir(path), mappedTarget)
			if err != nil {
				return fmt.Errorf("rebase cloned symlink %s: %w", path, err)
			}
		}
		if err := replaceSymlink(path, newTarget); err != nil {
			return fmt.Errorf("rebase cloned symlink %s: %w", path, err)
		}
		return nil
	})
}

func rebasePath(path, sourceRoot, cloneRoot string) (string, bool) {
	relative, err := filepath.Rel(filepath.Clean(sourceRoot), filepath.Clean(path))
	if err != nil || relative == ".." || strings.HasPrefix(relative, ".."+string(filepath.Separator)) {
		return "", false
	}
	if relative == "." {
		return filepath.Clean(cloneRoot), true
	}
	return filepath.Join(cloneRoot, relative), true
}

func replaceSymlink(path, target string) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".simslim-relink-")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	if err := temporary.Close(); err != nil {
		_ = os.Remove(temporaryPath)
		return err
	}
	if err := os.Remove(temporaryPath); err != nil {
		return err
	}
	if err := os.Symlink(target, temporaryPath); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		_ = os.Remove(temporaryPath)
		return err
	}
	return nil
}

func verifyCloneIndependence(paths cloneFilesystem) error {
	return filepath.WalkDir(paths.cloneDeviceDirectory, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.Type()&os.ModeSymlink != 0 {
			target, err := os.Readlink(path)
			if err != nil {
				return fmt.Errorf("read cloned symlink %s: %w", path, err)
			}
			resolvedTarget := target
			if !filepath.IsAbs(resolvedTarget) {
				resolvedTarget = filepath.Join(filepath.Dir(path), resolvedTarget)
			}
			resolvedTarget = filepath.Clean(resolvedTarget)
			if _, linked := rebasePath(resolvedTarget, paths.sourceDeviceDirectory, paths.cloneDeviceDirectory); linked ||
				pathContainsComponent(resolvedTarget, paths.sourceUDID) ||
				pathContainsComponent(target, paths.sourceUDID) {
				return fmt.Errorf("cloned symlink %s still resolves into the source simulator: %s", path, target)
			}
			return nil
		}
		if !entry.Type().IsRegular() {
			return nil
		}

		relative, err := filepath.Rel(paths.cloneDeviceDirectory, path)
		if err != nil {
			return err
		}
		sourcePath := filepath.Join(paths.sourceDeviceDirectory, relative)
		sourceInfo, err := os.Lstat(sourcePath)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return fmt.Errorf("inspect source counterpart %s: %w", sourcePath, err)
		}
		if !sourceInfo.Mode().IsRegular() {
			return nil
		}
		cloneInfo, err := entry.Info()
		if err != nil {
			return fmt.Errorf("inspect cloned file %s: %w", path, err)
		}
		if os.SameFile(sourceInfo, cloneInfo) {
			return fmt.Errorf("cloned file %s is hard-linked to the source simulator", path)
		}
		return nil
	})
}

type sourceReference struct {
	pid  int
	path string
}

const (
	cloneOpenFileAuditAttempts = 3
	cloneOpenFileAuditDelay    = 100 * time.Millisecond
)

// verifyRunningCloneDoesNotOpenSource makes the filesystem checks observable
// at runtime too. It catches a copied registry or preference that contains an
// absolute path even when that path is not represented by a symlink.
func verifyRunningCloneDoesNotOpenSource(ctx context.Context, paths cloneFilesystem) error {
	var lastErr error
	for attempt := 0; attempt < cloneOpenFileAuditAttempts; attempt++ {
		complete, err := auditRunningCloneOpenFilesOnce(ctx, paths)
		if complete {
			return err
		}
		lastErr = err
		if attempt+1 == cloneOpenFileAuditAttempts {
			break
		}
		timer := time.NewTimer(cloneOpenFileAuditDelay)
		select {
		case <-timer.C:
		case <-ctx.Done():
			if !timer.Stop() {
				select {
				case <-timer.C:
				default:
				}
			}
			return fmt.Errorf("audit cloned simulator open files: %w", ctx.Err())
		}
	}
	return lastErr
}

// auditRunningCloneOpenFilesOnce reports complete=false only when process churn
// prevented a meaningful snapshot. The caller retries those transient cases.
func auditRunningCloneOpenFilesOnce(ctx context.Context, paths cloneFilesystem) (complete bool, err error) {
	psOutput, err := exec.CommandContext(ctx, "/bin/ps", "eww", "-axo", "pid=,command=").Output()
	if err != nil {
		return true, fmt.Errorf("enumerate cloned simulator processes: %w", err)
	}
	pids := simulatorProcessIDsFromPS(string(psOutput), paths.cloneUDID)
	if len(pids) == 0 {
		return false, fmt.Errorf("could not identify any running processes for cloned simulator %s", paths.cloneUDID)
	}
	pidsText := make([]string, 0, len(pids))
	for _, pid := range pids {
		pidsText = append(pidsText, strconv.Itoa(pid))
	}
	lsofOutput, lsofErr := exec.CommandContext(
		ctx,
		"/usr/sbin/lsof",
		"-n",
		"-P",
		"-Fpn",
		"-p",
		strings.Join(pidsText, ","),
	).CombinedOutput()
	return evaluateCloneLsofAudit(string(lsofOutput), lsofErr, paths)
}

func evaluateCloneLsofAudit(output string, commandErr error, paths cloneFilesystem) (complete bool, err error) {
	references, hasRecords := parseCloneLsofOutput(output, paths)
	if len(references) > 0 {
		return true, fmt.Errorf(
			"clone process %d still has a source simulator path open: %s",
			references[0].pid,
			references[0].path,
		)
	}
	if hasRecords {
		// lsof exits 1 when any PID from the snapshot has already exited, even
		// though it emits complete records for every process that is still live.
		return true, nil
	}
	if commandErr != nil {
		message := strings.TrimSpace(output)
		if message == "" {
			return false, fmt.Errorf("audit cloned simulator open files: %w", commandErr)
		}
		return false, fmt.Errorf("audit cloned simulator open files: %w: %s", commandErr, message)
	}
	return false, fmt.Errorf("audit cloned simulator open files returned no process or path records")
}

func simulatorProcessIDsFromPS(output, udid string) []int {
	marker := "SIMULATOR_UDID=" + udid
	seen := make(map[int]bool)
	var pids []int
	for _, line := range strings.Split(output, "\n") {
		if !strings.Contains(line, marker) {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil || pid <= 0 || seen[pid] {
			continue
		}
		seen[pid] = true
		pids = append(pids, pid)
	}
	sort.Ints(pids)
	return pids
}

func sourceReferencesFromLsof(output string, paths cloneFilesystem) []sourceReference {
	references, _ := parseCloneLsofOutput(output, paths)
	return references
}

func parseCloneLsofOutput(output string, paths cloneFilesystem) (references []sourceReference, hasRecords bool) {
	currentPID := 0
	for _, line := range strings.Split(output, "\n") {
		if len(line) < 2 {
			continue
		}
		switch line[0] {
		case 'p':
			pid, err := strconv.Atoi(line[1:])
			if err != nil || pid <= 0 {
				currentPID = 0
				continue
			}
			currentPID = pid
		case 'n':
			if currentPID <= 0 {
				continue
			}
			hasRecords = true
			path := line[1:]
			_, inSourceDevice := rebasePath(path, paths.sourceDeviceDirectory, paths.cloneDeviceDirectory)
			_, inSourceLogs := rebasePath(path, paths.sourceLogDirectory, paths.cloneLogDirectory)
			if inSourceDevice || inSourceLogs {
				references = append(references, sourceReference{pid: currentPID, path: path})
			}
		}
	}
	return references, hasRecords
}

func pathContainsComponent(path, component string) bool {
	if component == "" {
		return false
	}
	for _, part := range strings.Split(filepath.Clean(path), string(filepath.Separator)) {
		if part == component {
			return true
		}
	}
	return false
}

// CloneOperationTimeout is deliberately derived from BootTimeout at call time
// because tests and CI may raise that variable for slow hosts.
func CloneOperationTimeout() time.Duration {
	return 3*BootTimeout + 2*ShutdownTimeout
}
