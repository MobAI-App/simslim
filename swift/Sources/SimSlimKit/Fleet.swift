import Foundation

/// One process in a simulator's launchd tree, for the `top` drill-down. (Named
/// apart from Foundation's `Process`; the JSON keys are the contract.)
public struct ProcessUsage: Codable, Equatable, Sendable {
  public var pid: Int
  public var command: String
  public var bytes: Int64
  public var cpu: Double

  public init(pid: Int, command: String, bytes: Int64, cpu: Double) {
    self.pid = pid
    self.command = command
    self.bytes = bytes
    self.cpu = cpu
  }
}

/// One booted simulator's live resource snapshot for `simslim top`.
public struct TopSim: Codable, Equatable, Sendable {
  public var device: Device
  public var managedDisabled: Int?
  public var managedTotal: Int
  public var statusError: String
  public var memory: MemoryMeasurement?
  public var memoryError: String
  public var diskBytes: Int64?

  public init(
    device: Device, managedDisabled: Int? = nil, managedTotal: Int = 0, statusError: String = "",
    memory: MemoryMeasurement? = nil, memoryError: String = "", diskBytes: Int64? = nil
  ) {
    self.device = device
    self.managedDisabled = managedDisabled
    self.managedTotal = managedTotal
    self.statusError = statusError
    self.memory = memory
    self.memoryError = memoryError
    self.diskBytes = diskBytes
  }

  private enum ExtraKeys: String, CodingKey {
    case managedDisabled, managedTotal, statusError, memory, memoryError, diskBytes
  }

  public func encode(to encoder: Encoder) throws {
    try device.encode(to: encoder)  // flatten the device's keys into this object
    var c = encoder.container(keyedBy: ExtraKeys.self)
    try c.encodeIfPresent(managedDisabled, forKey: .managedDisabled)
    try c.encode(managedTotal, forKey: .managedTotal)
    if !statusError.isEmpty { try c.encode(statusError, forKey: .statusError) }  // Go omitempty
    try c.encodeIfPresent(memory, forKey: .memory)
    if !memoryError.isEmpty { try c.encode(memoryError, forKey: .memoryError) }
    try c.encodeIfPresent(diskBytes, forKey: .diskBytes)
  }

  public init(from decoder: Decoder) throws {
    device = try Device(from: decoder)
    let c = try decoder.container(keyedBy: ExtraKeys.self)
    managedDisabled = try c.decodeIfPresent(Int.self, forKey: .managedDisabled)
    managedTotal = try c.decode(Int.self, forKey: .managedTotal)
    statusError = try c.decodeIfPresent(String.self, forKey: .statusError) ?? ""
    memory = try c.decodeIfPresent(MemoryMeasurement.self, forKey: .memory)
    memoryError = try c.decodeIfPresent(String.self, forKey: .memoryError) ?? ""
    diskBytes = try c.decodeIfPresent(Int64.self, forKey: .diskBytes)
  }
}

/// The fleet view: every booted simulator plus the summed footprint that decides
/// how many more fit.
public struct TopOutput: Codable, Equatable, Sendable {
  public var sims: [TopSim]
  public var totalBytes: Int64

  public init(sims: [TopSim] = [], totalBytes: Int64 = 0) {
    self.sims = sims
    self.totalBytes = totalBytes
  }
}

/// One simulator's per-daemon breakdown, the `top` drill-down.
public struct TopProcesses: Codable, Equatable, Sendable {
  public var udid: String
  public var name: String
  public var processes: [ProcessUsage]
  public var totalBytes: Int64

  public init(udid: String, name: String = "", processes: [ProcessUsage], totalBytes: Int64 = 0) {
    self.udid = udid
    self.name = name
    self.processes = processes
    self.totalBytes = totalBytes
  }

  private enum CodingKeys: String, CodingKey { case udid, name, processes, totalBytes }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(udid, forKey: .udid)
    if !name.isEmpty { try c.encode(name, forKey: .name) }  // Go omitempty
    try c.encode(processes, forKey: .processes)
    try c.encode(totalBytes, forKey: .totalBytes)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    udid = try c.decode(String.self, forKey: .udid)
    name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
    processes = try c.decode([ProcessUsage].self, forKey: .processes)
    totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
  }
}

extension Simctl {
  /// Every process in the device's launchd tree, largest footprint first.
  public func measureProcesses(udid: String) throws -> [ProcessUsage] {
    let root = try simLaunchdPID(udid: udid)
    let snapshot = try processSnapshot()
    let footprint = try footprintByPID()
    let procs = Simctl.treePIDs(root: root, children: snapshot.children).map { pid in
      ProcessUsage(
        pid: pid, command: snapshot.comm[pid] ?? "", bytes: footprint[pid] ?? 0,
        cpu: snapshot.cpu[pid] ?? 0)
    }
    return procs.sorted { a, b in
      a.bytes != b.bytes ? a.bytes > b.bytes : a.pid < b.pid
    }
  }

  /// The live resource view of every booted simulator: slim status and memory
  /// from one shared process snapshot; disk usage is optional because it runs
  /// `du` per device and is comparatively slow.
  public func fleetSnapshot(withDisk: Bool) throws -> TopOutput {
    let booted = try listDevices().filter { $0.state == "Booted" }
    let (memory, memoryErrors) = measureMany(udids: booted.map(\.udid))

    // Each simulator's status read is a simctl spawn; run them side by side.
    let slots = Slots<TopSim>(count: booted.count)
    DispatchQueue.concurrentPerform(iterations: booted.count) { i in
      let device = booted[i]
      var sim = TopSim(device: device)
      do {
        let status = try self.readStatus(for: device).status
        sim.managedDisabled = status.managedDisabled
        sim.managedTotal = status.managedTotal
      } catch {
        sim.statusError = error.localizedDescription
      }
      if withDisk, let bytes = try? self.deviceDiskUsage(udid: device.udid) {
        sim.diskBytes = bytes
      }
      slots.set(i, sim)
    }

    var out = TopOutput()
    for var sim in slots.values {
      if let measurement = memory[sim.device.udid] {
        sim.memory = measurement
        out.totalBytes += measurement.bytes
      } else if let message = memoryErrors[sim.device.udid] {
        sim.memoryError = message
      }
      out.sims.append(sim)
    }
    // Stable, so simulators without a measurement keep their listing order.
    out.sims = out.sims.enumerated().sorted { a, b in
      let (x, y) = (Simctl.topBytes(a.element), Simctl.topBytes(b.element))
      return x != y ? x > y : a.offset < b.offset
    }.map(\.element)
    return out
  }

  static func topBytes(_ sim: TopSim) -> Int64 { sim.memory?.bytes ?? -1 }

  /// Allocated filesystem blocks for one exact simulator device directory. The
  /// UDID is resolved through simctl first, so an alias such as `all` can never
  /// become a filesystem path.
  public func deviceDiskUsage(udid: String) throws -> Int64 {
    let (_, dataDirectory) = try simulatorDataDirectory(udid: udid)
    let devicePath = (dataDirectory as NSString).deletingLastPathComponent
    let result = try exec(.du, ["-sk", devicePath])
    guard result.succeeded else {
      throw SimSlimError(
        "measure simulator disk usage: exit status \(result.status): \(result.combinedText)")
    }
    return try Simctl.parseDUDiskUsage(result.stdoutText)
  }

  static func parseDUDiskUsage(_ output: String) throws -> Int64 {
    guard let field = output.split(whereSeparator: \.isWhitespace).first else {
      throw SimSlimError("du returned no disk usage")
    }
    guard let kib = Int64(field), kib >= 0, kib <= Int64.max / 1024 else {
      throw SimSlimError("parse du disk usage \"\(field)\"")
    }
    return kib * 1024
  }

  /// The exact device and its data directory, which must be a real directory.
  func simulatorDataDirectory(udid: String) throws -> (device: Device, dataDirectory: String) {
    let device = try findDevice(udid: udid)
    if device.dataPath.isEmpty { throw SimSlimError("simctl reported no data path for \(udid)") }
    var info = stat()
    guard lstat(device.dataPath, &info) == 0 else {
      throw SimSlimError("locate simulator data: \(String(cString: strerror(errno)))")
    }
    if (info.st_mode & S_IFMT) != S_IFDIR {
      throw SimSlimError("simulator data path is not a real directory: \(device.dataPath)")
    }
    return (device, device.dataPath)
  }
}

/// Fixed slots written from several threads, read in order afterwards.
private final class Slots<T>: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [T?]
  init(count: Int) { items = Array(repeating: nil, count: count) }
  func set(_ index: Int, _ value: T) {
    lock.lock()
    items[index] = value
    lock.unlock()
  }
  var values: [T] { items.compactMap { $0 } }
}
