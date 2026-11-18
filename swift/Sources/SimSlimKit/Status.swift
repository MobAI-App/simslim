// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// How slim a device currently is. The JSON keys are a contract with the app.
public struct Status: Codable, Equatable, Sendable {
  public var managedDisabled: Int  // managed labels currently disabled
  public var managedTotal: Int  // size of the managed universe
  public var booted: Bool
  public var persistent: Bool  // the runtime keeps disabled state across reboot

  public init(managedDisabled: Int, managedTotal: Int, booted: Bool, persistent: Bool) {
    self.managedDisabled = managedDisabled
    self.managedTotal = managedTotal
    self.booted = booted
    self.persistent = persistent
  }

  /// The static fields of a device's status, before its launchd state is read.
  public static func initial(for device: Device) -> Status {
    Status(
      managedDisabled: 0,
      managedTotal: Profile().desired(for: device).count,
      booted: device.state == "Booted",
      persistent: device.supportsPersistentOverrides)
  }

  /// "stock", "partially slim" or "slim".
  public var verdict: String {
    if managedDisabled == managedTotal { return "slim" }
    return managedDisabled > 0 ? "partially slim" : "stock"
  }
}

extension Device {
  var minimumPersistentVersion: String {
    switch platformName {
    case "watchOS": return "11.5"
    case "visionOS": return "2.5"
    default: return "18.5"
    }
  }

  /// Applies the launchd persistence version gate to the device's platform.
  /// tvOS 18.5, watchOS 11.5 and visionOS 2.5 are the release generation
  /// corresponding to iOS 18.5. This gate is not proof of persistence: slimming
  /// always reads overrides back after boot and fails if the runtime lost them.
  public var supportsPersistentOverrides: Bool {
    var minimumMajor = 18
    switch platformName {
    case "iOS", "tvOS": break
    case "watchOS": minimumMajor = 11
    case "visionOS": minimumMajor = 2
    default: return false
    }
    let parts = osVersion.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2, let major = Int(parts[0]), let minor = Int(parts[1]), minor >= 0 else {
      return false
    }
    return major > minimumMajor || (major == minimumMajor && minor >= 5)
  }
}

/// The managed launchd labels a category has disabled on a simulator, alongside
/// the feature that stops working as a result.
public struct DroppedCategory: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let downside: String
  public let labels: [String]
}

extension Catalog {
  /// Groups the disabled managed daemons by category, in category order,
  /// omitting categories with nothing disabled.
  public static func droppedCategories(disabled: Set<String>) -> [DroppedCategory] {
    categories.compactMap { category in
      let labels = category.labels.filter { disabled.contains($0) }.sorted()
      if labels.isEmpty { return nil }
      return DroppedCategory(
        id: category.id, name: category.name, downside: category.downside, labels: labels)
    }
  }
}

extension Simctl {
  /// Reads a booted device's status and its disabled labels.
  public func readStatus(for device: Device) throws -> (status: Status, disabled: Set<String>) {
    var status = Status.initial(for: device)
    guard status.booted else {
      throw SimSlimError("simulator must be booted to read its state (it is \(device.state))")
    }
    let managed = Profile().desired(for: device)
    let disabled = try readDisabled(set: device.set, udid: device.udid)
    status.managedDisabled = disabled.filter { managed.contains($0) }.count
    return (status, disabled)
  }

  public func readStatus(udid: String) throws -> (status: Status, disabled: Set<String>) {
    try readStatus(for: try findDevice(udid: udid))
  }
}
