import Foundation

/// Progress lines for operations that take minutes. The caller decides where
/// they go (the CLI sends them to stderr); a nil reporter is a no-op.
public typealias Reporter = @Sendable (String) -> Void

func report(_ reporter: Reporter?, _ message: String) { reporter?(message) }

extension Simctl {
  /// Runs `xcrun <args>` and turns a failure into Go's `xcrun <args>: exit status
  /// N: <output>`.
  func xcrunChecked(_ args: [String], timeout: TimeInterval? = nil) throws -> CommandResult {
    let result = try exec(.xcrun, args, timeout: timeout)
    if result.succeeded { return result }
    let reason = result.timedOut ? "signal: killed" : "exit status \(result.status)"
    throw SimSlimError("xcrun \(args.joined(separator: " ")): \(reason): \(result.combinedText)")
  }

  public static let shutdownTimeout: TimeInterval = 30

  /// Boots the device, tolerating one that is already booted, and blocks on
  /// `bootstatus -b` until its services are ready.
  public func bootAndWait(set: String, udid: String) throws {
    let boot = try exec(.xcrun, simctlArgs(set: set, ["boot", udid]))
    if !boot.succeeded {
      let message = boot.combinedText
      if !message.contains("already booted") && !message.contains("current state: Booted") {
        throw SimSlimError("simctl boot: exit status \(boot.status): \(message)")
      }
    }
    _ = try xcrunChecked(simctlArgs(set: set, ["bootstatus", udid, "-b"]))
  }

  /// Shuts the device down, tolerating one that is already shut down.
  public func shutdown(set: String, udid: String) throws {
    let result = try exec(.xcrun, simctlArgs(set: set, ["shutdown", udid]))
    if result.succeeded { return }
    if result.combinedText.contains("current state: Shutdown") { return }
    throw SimSlimError("simctl shutdown: exit status \(result.status): \(result.combinedText)")
  }

  /// Polls until the device reports Shutdown.
  public func waitShutdown(
    set: String, udid: String, timeout: TimeInterval = Simctl.shutdownTimeout
  ) throws {
    let limit = now().addingTimeInterval(timeout)
    while now() < limit {
      if try findDevice(udid: udid, set: set).state == "Shutdown" { return }
      sleep(0.5)
    }
    throw SimSlimError("timed out waiting for \(udid) to shut down")
  }

  /// Shuts the device down and waits for it, under the shutdown timeout.
  public func shutdownAndWait(set: String, udid: String) throws {
    var bounded = self
    bounded.deadline = now().addingTimeInterval(Simctl.shutdownTimeout)
    try bounded.shutdown(set: set, udid: udid)
    try bounded.waitShutdown(set: set, udid: udid)
  }

  /// The host path of a CoreSimulator runtime's RuntimeRoot. Simulator processes
  /// see the host file system, so launchctl inside the simulator can read job
  /// plists by these paths. Runtimes are global, never per device set.
  func runtimeRoot(runtimeID: String) throws -> String {
    let result = try exec(.xcrun, ["simctl", "list", "runtimes", "-j"])
    guard result.succeeded else {
      throw Simctl.listError(status: result.status, stderr: result.stderrText)
    }
    return try Simctl.parseRuntimeRoot(result.stdout, runtimeID: runtimeID)
  }

  static func parseRuntimeRoot(_ data: Data, runtimeID: String) throws -> String {
    struct Runtimes: Decodable {
      struct Entry: Decodable {
        var identifier: String?
        var runtimeRoot: String?
      }
      var runtimes: [Entry]
    }
    let parsed: Runtimes
    do {
      parsed = try JSONDecoder().decode(Runtimes.self, from: data)
    } catch {
      throw SimSlimError("parse simctl list runtimes: \(error.localizedDescription)")
    }
    for entry in parsed.runtimes where entry.identifier == runtimeID {
      if let root = entry.runtimeRoot, !root.isEmpty { return root }
    }
    throw SimSlimError("runtime \(runtimeID) has no runtimeRoot")
  }
}

// MARK: - Management

/// Go's `unicode.IsSpace` set: Foundation's `.whitespacesAndNewlines` also trims
/// U+200B, which Go does not.
private let goSpace: Set<UInt32> = {
  var set: Set<UInt32> = [
    0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0x85, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F,
    0x3000,
  ]
  for value in UInt32(0x2000)...UInt32(0x200A) { set.insert(value) }
  return set
}()

func goTrimSpace(_ text: String) -> String {
  var scalars = Substring(text).unicodeScalars
  while let last = scalars.last, goSpace.contains(last.value) { scalars.removeLast() }
  while let first = scalars.first, goSpace.contains(first.value) { scalars.removeFirst() }
  return String(scalars)
}

/// Trims a simulator name and rejects what simctl or the app could not show.
public func normalizeSimulatorName(_ name: String) throws -> String {
  let trimmed = goTrimSpace(name)
  if trimmed.isEmpty { throw SimSlimError("simulator name cannot be empty") }
  if trimmed.unicodeScalars.count > 128 {
    throw SimSlimError("simulator name cannot exceed 128 characters")
  }
  if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
    throw SimSlimError("simulator name cannot contain control characters")
  }
  return trimmed
}

extension Simctl {
  /// Resolves the exact device before any destructive command, so a simctl alias
  /// such as `all` can never enter these code paths, and shuts it down if it is
  /// booted. Returns the device's set so the caller can target its own simctl
  /// call there.
  func shutdownIfBooted(udid: String) throws -> String {
    let device = try findDevice(udid: udid)
    // Go would run erase/delete on a device that is Booting or Shutting Down.
    // Both are permanent, so wait for a settled state instead.
    if device.state != "Booted" && device.state != "Shutdown" {
      throw SimSlimError(
        "simulator \(udid) is \(device.state); wait until it is Booted or Shutdown, then try again")
    }
    if device.state != "Booted" { return device.set }
    try shutdown(set: device.set, udid: udid)
    try waitShutdown(set: device.set, udid: udid)
    return device.set
  }

  public func renameDevice(udid: String, name: String) throws {
    let device = try findDevice(udid: udid)
    let clean = try normalizeSimulatorName(name)
    _ = try xcrunChecked(simctlArgs(set: device.set, ["rename", udid, clean]))
  }

  public func eraseDevice(udid: String) throws {
    let set = try shutdownIfBooted(udid: udid)
    _ = try xcrunChecked(simctlArgs(set: set, ["erase", udid]))
  }

  public func deleteDevice(udid: String) throws {
    let set = try shutdownIfBooted(udid: udid)
    _ = try xcrunChecked(simctlArgs(set: set, ["delete", udid]))
  }
}
