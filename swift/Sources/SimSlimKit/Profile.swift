// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// Selects which managed daemons a slim boot should disable.
public struct Profile: Equatable, Sendable {
  public var exceptCategories: Set<String>  // category IDs to leave fully enabled
  public var keep: Set<String>  // individual labels to leave enabled

  public init(exceptCategories: Set<String> = [], keep: Set<String> = []) {
    self.exceptCategories = exceptCategories
    self.keep = keep
  }

  /// The labels this profile wants disabled. Categories may share labels, so a
  /// label stays enabled when any excepted category lists it.
  public func desired() -> Set<String> {
    var set = Catalog.slimmableSet
    for category in Catalog.categories where exceptCategories.contains(category.id) {
      set.subtract(category.labels)
    }
    set.subtract(keep)
    return set
  }

  /// Applies platform-specific service requirements. `desired()` remains the
  /// platform-independent catalog for profile editors.
  public func desired(for device: Device) -> Set<String> {
    desiredForDevice(device, desired())
  }
}

func desiredForDevice(_ device: Device, _ desired: Set<String>) -> Set<String> {
  desired.filter { label in
    // watchOS re-enables homed after startup, even when launchd initially
    // honours the override. Keep it enabled rather than report a full slim
    // that drifts as soon as the Watch finishes starting up.
    if device.platformName == "watchOS" && label == "com.apple.homed" { return false }
    // visionOS serves the simulated surroundings as mobile assets. Without
    // mobileassetd the device boots into a black space.
    if device.platformName == "visionOS" && label == "com.apple.mobileassetd" { return false }
    return true
  }
}

/// The launchctl transitions that move `current` to `desired`, scoped to
/// `managed`. Labels outside `managed` are never touched: an unmanaged desired
/// label is ignored, and an unmanaged label that is already disabled stays
/// disabled. Empty results mean the device is already correct.
public func delta(
  current: Set<String>, desired: Set<String>, managed: Set<String>
) -> (toDisable: [String], toEnable: [String]) {
  let toDisable = desired.filter { managed.contains($0) && !current.contains($0) }
  let toEnable = current.filter { managed.contains($0) && !desired.contains($0) }
  return (toDisable.sorted(), toEnable.sorted())
}
