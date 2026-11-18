import Foundation

/// Progress lines for operations that take minutes. The caller decides where
/// they go (the CLI sends them to stderr); a nil reporter is a no-op.
public typealias Reporter = @Sendable (String) -> Void

func report(_ reporter: Reporter?, _ message: String) { reporter?(message) }

extension Simctl {
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
    let status = try exec(.xcrun, simctlArgs(set: set, ["bootstatus", udid, "-b"]))
    guard status.succeeded else {
      throw SimSlimError("simctl bootstatus: exit status \(status.status): \(status.combinedText)")
    }
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
