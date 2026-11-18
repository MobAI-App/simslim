// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// The stable, machine-readable shapes the macOS app and other integrations
/// decode. Changing a field breaks `gui/*.swift`; keep them in sync.

/// A device plus its slim status and memory. The device fields are flattened
/// into the same JSON object, as in the Go output.
public struct DeviceSummary: Codable, Equatable, Sendable {
  public var device: Device
  public var managedDisabled: Int?  // omitted for shutdown simulators
  public var managedTotal: Int
  public var statusError: String
  public var memory: MemoryMeasurement?
  public var memoryError: String

  public init(
    device: Device, managedDisabled: Int? = nil, managedTotal: Int, statusError: String = "",
    memory: MemoryMeasurement? = nil, memoryError: String = ""
  ) {
    self.device = device
    self.managedDisabled = managedDisabled
    self.managedTotal = managedTotal
    self.statusError = statusError
    self.memory = memory
    self.memoryError = memoryError
  }

  private enum ExtraKeys: String, CodingKey {
    case managedDisabled, managedTotal, statusError, memory, memoryError
  }

  public func encode(to encoder: Encoder) throws {
    try device.encode(to: encoder)  // flatten the device's keys into this object
    var c = encoder.container(keyedBy: ExtraKeys.self)
    try c.encodeIfPresent(managedDisabled, forKey: .managedDisabled)
    try c.encode(managedTotal, forKey: .managedTotal)
    if !statusError.isEmpty { try c.encode(statusError, forKey: .statusError) }  // Go omitempty
    try c.encodeIfPresent(memory, forKey: .memory)
    if !memoryError.isEmpty { try c.encode(memoryError, forKey: .memoryError) }
  }

  public init(from decoder: Decoder) throws {
    device = try Device(from: decoder)
    let c = try decoder.container(keyedBy: ExtraKeys.self)
    managedDisabled = try c.decodeIfPresent(Int.self, forKey: .managedDisabled)
    managedTotal = try c.decode(Int.self, forKey: .managedTotal)
    statusError = try c.decodeIfPresent(String.self, forKey: .statusError) ?? ""
    memory = try c.decodeIfPresent(MemoryMeasurement.self, forKey: .memory)
    memoryError = try c.decodeIfPresent(String.self, forKey: .memoryError) ?? ""
  }
}

/// `simslim status --json`: the status fields flattened, plus the verdict and,
/// only with `--dropped`, the disabled daemons grouped by category.
public struct StatusOutput: Codable, Equatable, Sendable {
  public var status: Status
  public var verdict: String
  public var dropped: [DroppedCategory]

  public init(status: Status, verdict: String, dropped: [DroppedCategory] = []) {
    self.status = status
    self.verdict = verdict
    self.dropped = dropped
  }

  private enum ExtraKeys: String, CodingKey { case verdict, dropped }

  public func encode(to encoder: Encoder) throws {
    try status.encode(to: encoder)
    var c = encoder.container(keyedBy: ExtraKeys.self)
    try c.encode(verdict, forKey: .verdict)
    if !dropped.isEmpty { try c.encode(dropped, forKey: .dropped) }  // Go omitempty
  }

  public init(from decoder: Decoder) throws {
    status = try Status(from: decoder)
    let c = try decoder.container(keyedBy: ExtraKeys.self)
    verdict = try c.decode(String.self, forKey: .verdict)
    dropped = try c.decodeIfPresent([DroppedCategory].self, forKey: .dropped) ?? []
  }
}

/// The result of a simulator lifecycle command (`boot`, `shutdown`, ...).
public struct SimulatorMutationOutput: Codable, Equatable, Sendable {
  public var action: String
  public var udid: String
  public var name: String
  public var sourceUdid: String

  public init(action: String, udid: String, name: String = "", sourceUdid: String = "") {
    self.action = action
    self.udid = udid
    self.name = name
    self.sourceUdid = sourceUdid
  }

  private enum CodingKeys: String, CodingKey { case action, udid, name, sourceUdid }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(action, forKey: .action)
    try c.encode(udid, forKey: .udid)
    if !name.isEmpty { try c.encode(name, forKey: .name) }  // Go omitempty
    if !sourceUdid.isEmpty { try c.encode(sourceUdid, forKey: .sourceUdid) }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    action = try c.decode(String.self, forKey: .action)
    udid = try c.decode(String.self, forKey: .udid)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    sourceUdid = try c.decodeIfPresent(String.self, forKey: .sourceUdid) ?? ""
  }
}

/// The result of `enable` and `disable`.
public struct ServicesOutput: Codable, Equatable, Sendable {
  public var action: String  // "enable" or "disable"
  public var udid: String
  public var live: Bool  // false: the simulator is not booted, only the profile was saved
  public var labels: [String]  // daemons enabled, or stopped by disable
  public var notStarted: [String]  // enable: re-enabled, but launchd starts them at the next boot
  public var stillEnabled: [String]  // disable: kept running for another category or the platform
  public var saved: String  // the profile file --save created or updated

  public init(
    action: String, udid: String, live: Bool, labels: [String] = [], notStarted: [String] = [],
    stillEnabled: [String] = [], saved: String = ""
  ) {
    self.action = action
    self.udid = udid
    self.live = live
    self.labels = labels
    self.notStarted = notStarted
    self.stillEnabled = stillEnabled
    self.saved = saved
  }

  private enum CodingKeys: String, CodingKey {
    case action, udid, live, labels, notStarted, stillEnabled, saved
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(action, forKey: .action)
    try c.encode(udid, forKey: .udid)
    try c.encode(live, forKey: .live)
    try c.encode(labels, forKey: .labels)  // always present, `[]` when empty
    if !notStarted.isEmpty { try c.encode(notStarted, forKey: .notStarted) }  // Go omitempty
    if !stillEnabled.isEmpty { try c.encode(stillEnabled, forKey: .stillEnabled) }
    if !saved.isEmpty { try c.encode(saved, forKey: .saved) }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    action = try c.decode(String.self, forKey: .action)
    udid = try c.decode(String.self, forKey: .udid)
    live = try c.decode(Bool.self, forKey: .live)
    labels = try c.decode([String].self, forKey: .labels)
    notStarted = try c.decodeIfPresent([String].self, forKey: .notStarted) ?? []
    stillEnabled = try c.decodeIfPresent([String].self, forKey: .stillEnabled) ?? []
    saved = try c.decodeIfPresent(String.self, forKey: .saved) ?? ""
  }
}
