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
