import Foundation
import SimSlimKit

/// A simulated host for tests: it answers the `xcrun simctl`, `pgrep`, `ps` and
/// `top` calls simslim makes, from data the test provides, and records every
/// call. No real process is ever started.
public final class FakeHost: CommandRunning, @unchecked Sendable {
  public struct FakeDevice {
    public var udid: String
    public var name: String
    public var runtime: String
    public var state: String
    public var isAvailable: Bool

    public init(
      udid: String, name: String, runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-2",
      state: String = "Shutdown", isAvailable: Bool = true
    ) {
      self.udid = udid
      self.name = name
      self.runtime = runtime
      self.state = state
      self.isAvailable = isAvailable
    }
  }

  public struct Call: Equatable {
    public var executable: Executable
    public var arguments: [String]
    public var timeout: TimeInterval?
  }

  private let lock = NSLock()
  private var _calls: [Call] = []
  private var spawnQueues: [String: [CommandResult]] = [:]

  /// Devices in the default set.
  public var devices: [FakeDevice]
  /// Devices per extra set token (for example "testing"); a set absent here
  /// fails to list, like a set that does not exist.
  public var sets: [String: [FakeDevice]] = [:]
  /// `launchctl print-disabled` state per UDID, as `label => disabled` lines.
  public var disabled: [String: Set<String>] = [:]
  /// pid of each booted simulator's launchd, as pgrep reports it.
  public var launchdPIDs: [String: Int] = [:]
  public var psOutput = ""
  public var topOutput = ""
  /// When set, `simctl list` for the default set fails with this stderr.
  public var listFailure: String?

  public init(devices: [FakeDevice] = []) {
    self.devices = devices
  }

  public var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  /// Queues results returned, in order, by the next `print-disabled` spawns for a
  /// UDID before the normal answer resumes: used to simulate launchd error 124.
  public func queueSpawnResults(udid: String, _ results: [CommandResult]) {
    lock.lock()
    spawnQueues[udid, default: []].append(contentsOf: results)
    lock.unlock()
  }

  public func run(_ executable: Executable, _ arguments: [String], timeout: TimeInterval?) throws
    -> CommandResult
  {
    lock.lock()
    _calls.append(Call(executable: executable, arguments: arguments, timeout: timeout))
    lock.unlock()

    switch executable {
    case .xcrun: return xcrun(arguments)
    case .pgrep: return pgrep(arguments)
    case .ps: return CommandResult(status: 0, stdout: Data(psOutput.utf8))
    case .top: return CommandResult(status: 0, stdout: Data(topOutput.utf8))
    default:
      return CommandResult(status: 127, stderr: Data("FakeHost: unexpected \(executable)".utf8))
    }
  }

  // MARK: - Answers

  private func xcrun(_ args: [String]) -> CommandResult {
    guard args.first == "simctl" else { return failure("unexpected xcrun \(args)") }
    var rest = Array(args.dropFirst())
    var token = ""
    if rest.first == "--set", rest.count >= 2 {
      token = rest[1]
      rest = Array(rest.dropFirst(2))
    }

    if rest == ["list", "devices", "-j"] { return list(token: token) }
    if rest.count == 5, rest[0] == "spawn", rest[2] == "launchctl", rest[3] == "print-disabled",
      rest[4] == "system"
    {
      return printDisabled(udid: rest[1])
    }
    return failure("FakeHost: unhandled simctl \(rest)")
  }

  private func list(token: String) -> CommandResult {
    let source: [FakeDevice]
    if token.isEmpty {
      if let listFailure { return CommandResult(status: 1, stderr: Data(listFailure.utf8)) }
      source = devices
    } else if let set = sets[token] {
      source = set
    } else {
      return CommandResult(status: 1, stderr: Data("Invalid device set: \(token)".utf8))
    }

    var byRuntime: [String: [[String: Any]]] = [:]
    for device in source {
      byRuntime[device.runtime, default: []].append([
        "udid": device.udid, "name": device.name, "state": device.state,
        "isAvailable": device.isAvailable, "dataPath": "/fake/\(device.udid)/data",
      ])
    }
    let data = try! JSONSerialization.data(withJSONObject: ["devices": byRuntime])
    return CommandResult(status: 0, stdout: data)
  }

  private func printDisabled(udid: String) -> CommandResult {
    lock.lock()
    if var queue = spawnQueues[udid], !queue.isEmpty {
      let next = queue.removeFirst()
      spawnQueues[udid] = queue
      lock.unlock()
      return next
    }
    lock.unlock()

    guard let labels = disabled[udid] else {
      return CommandResult(status: 1, stderr: Data("Unable to find device \(udid)".utf8))
    }
    var text = "disabled services = {\n"
    for label in labels.sorted() { text += "\t\"\(label)\" => disabled\n" }
    text += "\t\"com.apple.some.enabled.service\" => enabled\n}\n"
    return CommandResult(status: 0, stdout: Data(text.utf8))
  }

  private func pgrep(_ args: [String]) -> CommandResult {
    guard args.count == 2, args[0] == "-f" else { return failure("unexpected pgrep \(args)") }
    for (udid, pid) in launchdPIDs where args[1].hasPrefix(udid) {
      return CommandResult(status: 0, stdout: Data("\(pid)\n".utf8))
    }
    return CommandResult(status: 1)
  }

  private func failure(_ message: String) -> CommandResult {
    CommandResult(status: 99, stderr: Data(message.utf8))
  }
}
