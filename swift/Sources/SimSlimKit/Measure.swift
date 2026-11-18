// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// A device's real memory cost.
public struct MemoryMeasurement: Codable, Equatable, Sendable {
  public var processes: Int
  /// Summed phys_footprint (compressed + dirty): the number that caps how many
  /// simulators fit.
  public var bytes: Int64
  /// Summed %cpu across the tree (ps's decaying average; can exceed 100).
  public var cpu: Double

  public init(processes: Int, bytes: Int64, cpu: Double) {
    self.processes = processes
    self.bytes = bytes
    self.cpu = cpu
  }
}

/// One `ps` sweep of every process: parent links, cpu, and name.
struct ProcessSnapshot: Equatable {
  var children: [Int: [Int]] = [:]
  var cpu: [Int: Double] = [:]
  var comm: [Int: String] = [:]
}

extension Simctl {
  /// Sums the phys_footprint of every process in the device's launchd tree.
  /// phys_footprint (the value Activity Monitor's "Memory" column reports)
  /// counts compressed and swapped pages, so it stays accurate under memory
  /// pressure where resident size would read misleadingly low.
  public func measure(udid: String) throws -> MemoryMeasurement {
    let root = try simLaunchdPID(udid: udid)
    let snapshot = try processSnapshot()
    let footprint = try footprintByPID()
    return Simctl.measureTree(root: root, snapshot: snapshot, footprint: footprint)
  }

  /// Takes one process and footprint snapshot for every requested simulator, so
  /// the RAM column stays current without running the relatively expensive `top`
  /// once per booted device. Returns measurements and per-UDID error messages.
  public func measureMany(udids: [String]) -> (
    measurements: [String: MemoryMeasurement], errors: [String: String]
  ) {
    var measurements: [String: MemoryMeasurement] = [:]
    var errors: [String: String] = [:]
    var roots: [String: Int] = [:]
    for udid in udids {
      do {
        roots[udid] = try simLaunchdPID(udid: udid)
      } catch {
        errors[udid] = error.localizedDescription
      }
    }
    if roots.isEmpty { return (measurements, errors) }

    do {
      let snapshot = try processSnapshot()
      let footprint = try footprintByPID()
      for (udid, root) in roots {
        measurements[udid] = Simctl.measureTree(
          root: root, snapshot: snapshot, footprint: footprint)
      }
    } catch {
      for udid in roots.keys { errors[udid] = error.localizedDescription }
    }
    return (measurements, errors)
  }

  func simLaunchdPID(udid: String) throws -> Int {
    let notBooted = SimSlimError("simulator \(udid) does not appear to be booted")
    let result: CommandResult
    do {
      result = try runner.run(.pgrep, ["-f", udid + "/data/var/run/launchd_bootstrap"])
    } catch {
      throw notBooted
    }
    guard result.succeeded,
      let first = result.stdoutText.split(whereSeparator: \.isWhitespace).first
    else { throw notBooted }
    guard let pid = Int(first) else {
      throw SimSlimError("unexpected pgrep output: \(first)")
    }
    return pid
  }

  func processSnapshot() throws -> ProcessSnapshot {
    // comm is the full executable path (untruncated, unlike ucomm); the basename
    // is what the drill-down shows (backboardd, SpringBoard, ...).
    let result = try runner.run(.ps, ["-axo", "pid,ppid,%cpu,comm"])
    guard result.succeeded else {
      throw SimSlimError("ps: exit status \(result.status): \(result.combinedText)")
    }
    return Simctl.parsePS(result.stdoutText)
  }

  func footprintByPID() throws -> [Int: Int64] {
    let result = try runner.run(.top, ["-l", "1", "-stats", "pid,mem"])
    guard result.succeeded else {
      throw SimSlimError("top: exit status \(result.status): \(result.combinedText)")
    }
    return Simctl.parseTopMemory(result.stdoutText)
  }

  static func measureTree(
    root: Int, snapshot: ProcessSnapshot, footprint: [Int: Int64]
  ) -> MemoryMeasurement {
    var measurement = MemoryMeasurement(processes: 0, bytes: 0, cpu: 0)
    for pid in treePIDs(root: root, children: snapshot.children) {
      measurement.processes += 1
      measurement.bytes += footprint[pid] ?? 0
      measurement.cpu += snapshot.cpu[pid] ?? 0
    }
    return measurement
  }

  /// Every pid reachable from `root` through the child map.
  static func treePIDs(root: Int, children: [Int: [Int]]) -> Set<Int> {
    var seen = Set<Int>()
    var stack = [root]
    while let pid = stack.popLast() {
      if !seen.insert(pid).inserted { continue }
      stack.append(contentsOf: children[pid] ?? [])
    }
    return seen
  }

  static func parsePS(_ output: String) -> ProcessSnapshot {
    var snapshot = ProcessSnapshot()
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.count < 4 { continue }
      guard let pid = Int(fields[0]), let ppid = Int(fields[1]) else { continue }
      snapshot.children[ppid, default: []].append(pid)
      if let cpu = Double(fields[2]) { snapshot.cpu[pid] = cpu }
      // Joining defends against spaces in the executable path.
      snapshot.comm[pid] = commName(fields[3...].joined(separator: " "))
    }
    return snapshot
  }

  /// Reduces a full executable path to its basename.
  static func commName(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
  }

  /// Parses `top -l 1 -stats pid,mem` lines: a pid, then a size such as `45M`
  /// or `1234K+`. Anything else (headers, the summary block) is skipped.
  static func parseTopMemory(_ output: String) -> [Int: Int64] {
    var memory: [Int: Int64] = [:]
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, fields[0].allSatisfy(\.isASCIIDigit), let pid = Int(fields[0]) else {
        continue
      }
      // The size must start with a digit or '.', like the Go regex's [0-9.]+.
      guard let first = fields[1].first, first.isASCIIDigit || first == "." else { continue }
      memory[pid] = parseBytes(String(fields[1]))
    }
    return memory
  }

  /// Parses sizes such as `45M`, `1.5G`, `900K+` or `12B`; the suffix is
  /// optional. Unparseable input is 0.
  static func parseBytes(_ text: String) -> Int64 {
    var s = text.trimmingCharacters(in: .whitespaces)
    if s.hasSuffix("+") { s.removeLast() }
    if s.hasSuffix("-") { s.removeLast() }
    if s.isEmpty { return 0 }
    var multiplier: Double = 1
    switch s.last {
    case "K":
      multiplier = 1_024
      s.removeLast()
    case "M":
      multiplier = 1_048_576
      s.removeLast()
    case "G":
      multiplier = 1_073_741_824
      s.removeLast()
    case "B": s.removeLast()
    default: break
    }
    guard let value = Double(s) else { return 0 }
    // Int64(_:) traps on overflow and NaN; an unparseable size is 0.
    return Int64(exactly: (value * multiplier).rounded(.towardZero)) ?? 0
  }
}

extension Character {
  fileprivate var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
