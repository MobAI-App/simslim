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

  // MARK: Mutable simulator behaviour

  /// Directory standing in for /private/var/tmp: a boot reads
  /// `com.apple.CoreSimulator.SimDevice.<udid>/disabled.plist` from it.
  public var storeRoot: String?
  /// Whether a boot honours that file (a runtime may ignore it).
  public var honoursStore = true
  /// Whether disable overrides survive a shutdown (iOS before 18.5 forgets them).
  public var persistsOverrides = true
  /// Labels loaded in each booted simulator's launchd.
  public var loaded: [String: Set<String>] = [:]
  /// Job plist path to the Label inside it, as plutil reports it.
  public var plistLabels: [String: String] = [:]
  /// runtime identifier to RuntimeRoot, for `simctl list runtimes -j`.
  public var runtimeRoots: [String: String] = [:]
  /// Decides a failure for a transition: (verb, label) -> result, or nil to succeed.
  public var failTransition: (@Sendable (String, String) -> CommandResult?)?
  /// Fails `simctl boot` / `shutdown` / `bootstatus` with this stderr when set.
  public var bootFailure: String?
  public var shutdownFailure: String?
  /// Fails `simctl bootstatus` but leaves the device Booted, as a boot that
  /// started and never became ready.
  public var bootstatusFailure: String?
  /// When set, a device's `dataPath` is `<dataRoot>/<udid>/data` instead of a
  /// path that does not exist, so a test can create (or deliberately not create)
  /// the directory.
  public var dataRoot: String?
  /// Makes `simctl list` report no data path for any device.
  public var emptyDataPath = false
  /// `du -sk` answers by path, in KiB; a path absent here makes `du` fail.
  public var duKiB: [String: Int] = [:]
  /// Fails `simctl rename` / `erase` / `delete` with this stderr when set.
  public var managementFailure: String?
  /// UDIDs `simctl clone` hands out, in order.
  public var cloneUDIDs: [String] = []
  /// Fails `simctl clone` with this stderr when set.
  public var cloneFailure: String?
  /// Makes `simctl clone` put the new device in this set instead of the source's.
  public var cloneIntoSet: String?
  /// Replaces what `simctl clone` prints, to exercise a malformed answer.
  public var cloneOutput: String?
  /// Answers `lsof -p <pids>`; nil gives each pid one harmless open file.
  public var lsofResult: (@Sendable ([Int]) -> CommandResult)?
  /// Makes the device ignore shutdown, to exercise the shutdown timeout.
  public var stuckBooted = false
  /// Called at the start of every command, with the arguments; lets a test
  /// observe ordering or inject behaviour.
  public var onCall: (@Sendable (Executable, [String]) -> Void)?

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
    onCall?(executable, arguments)

    switch executable {
    case .plutil: return plutil(arguments)
    case .xcrun: return xcrun(arguments)
    case .pgrep: return pgrep(arguments)
    case .ps: return CommandResult(status: 0, stdout: Data(psOutput.utf8))
    case .top: return CommandResult(status: 0, stdout: Data(topOutput.utf8))
    case .lsof:
      let pids = (arguments.last ?? "").split(separator: ",").compactMap { Int($0) }
      if let lsofResult { return lsofResult(pids) }
      let text = pids.map { "p\($0)\nn/dev/null\n" }.joined()
      return CommandResult(status: 0, stdout: Data(text.utf8))
    case .du:
      guard arguments.count == 2, arguments[0] == "-sk", let kib = duKiB[arguments[1]] else {
        return CommandResult(
          status: 1, stderr: Data("du: \(arguments.last ?? ""): No such file or directory".utf8))
      }
      return CommandResult(status: 0, stdout: Data("\(kib)\t\(arguments[1])\n".utf8))
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
    if let result = mutating(rest, token: token) { return result }
    return failure("FakeHost: unhandled simctl \(rest)")
  }

  // MARK: - State changes

  /// Like simctl, a device is only visible through the `--set` it lives in.
  private func setState(_ udid: String, _ state: String, token: String) -> Bool {
    if token.isEmpty {
      guard let i = devices.firstIndex(where: { $0.udid == udid }) else { return false }
      devices[i].state = state
      return true
    }
    guard let i = sets[token]?.firstIndex(where: { $0.udid == udid }) else { return false }
    sets[token]![i].state = state
    return true
  }

  private func withDevice(_ udid: String, token: String, _ change: (inout FakeDevice) -> Void)
    -> CommandResult
  {
    if token.isEmpty {
      guard let i = devices.firstIndex(where: { $0.udid == udid }) else {
        return failure("Invalid device")
      }
      change(&devices[i])
    } else {
      guard let i = sets[token]?.firstIndex(where: { $0.udid == udid }) else {
        return failure("Invalid device")
      }
      change(&sets[token]![i])
    }
    return CommandResult(status: 0)
  }

  private func stateOf(_ udid: String, token: String) -> String? {
    (token.isEmpty ? devices : sets[token] ?? []).first { $0.udid == udid }?.state
  }

  /// The boolean entries launchd_sim would read from the store at start.
  private func storeEntries(_ udid: String) -> [String: Bool] {
    guard let storeRoot else { return [:] }
    let path = "\(storeRoot)/com.apple.CoreSimulator.SimDevice.\(udid)/disabled.plist"
    guard let data = FileManager.default.contents(atPath: path),
      let object = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil),
      let dict = object as? [String: Any]
    else { return [:] }
    return dict.compactMapValues { $0 as? Bool }
  }

  private func mutating(_ rest: [String], token: String) -> CommandResult? {
    lock.lock()
    defer { lock.unlock() }
    guard let verb = rest.first else { return nil }
    switch verb {
    case "boot" where rest.count == 2:
      let udid = rest[1]
      if let bootFailure { return CommandResult(status: 1, stderr: Data(bootFailure.utf8)) }
      guard let state = stateOf(udid, token: token) else {
        return failure("Invalid device: \(udid)")
      }
      if state == "Booted" {
        return CommandResult(
          status: 149, stderr: Data("Unable to boot device in current state: Booted".utf8))
      }
      _ = setState(udid, "Booted", token: token)
      var live = persistsOverrides ? (disabled[udid] ?? []) : []
      if honoursStore {
        // The store is authoritative: an explicit true disables, an explicit
        // false enables even what was disabled before.
        for (label, off) in storeEntries(udid) {
          if off { live.insert(label) } else { live.remove(label) }
        }
      }
      disabled[udid] = live
      loaded[udid] = loaded[udid] ?? Self.defaultLoaded
      loaded[udid]!.subtract(live)
      return CommandResult(status: 0)
    case "bootstatus" where rest.count == 3:
      if let bootstatusFailure {
        return CommandResult(status: 1, stderr: Data(bootstatusFailure.utf8))
      }
      return stateOf(rest[1], token: token) == "Booted"
        ? CommandResult(status: 0) : CommandResult(status: 1, stderr: Data("not booted".utf8))
    case "shutdown" where rest.count == 2:
      let udid = rest[1]
      if let shutdownFailure { return CommandResult(status: 1, stderr: Data(shutdownFailure.utf8)) }
      guard let state = stateOf(udid, token: token) else {
        return failure("Invalid device: \(udid)")
      }
      if state != "Booted" {
        return CommandResult(
          status: 149, stderr: Data("Unable to shutdown device in current state: Shutdown".utf8))
      }
      if !stuckBooted { _ = setState(udid, "Shutdown", token: token) }
      return CommandResult(status: 0)
    case "rename" where rest.count == 3:
      if let managementFailure {
        return CommandResult(status: 1, stderr: Data(managementFailure.utf8))
      }
      guard stateOf(rest[1], token: token) != nil else {
        return failure("Invalid device: \(rest[1])")
      }
      return withDevice(rest[1], token: token) { $0.name = rest[2] }
    case "erase" where rest.count == 2:
      if let managementFailure {
        return CommandResult(status: 1, stderr: Data(managementFailure.utf8))
      }
      guard let state = stateOf(rest[1], token: token) else {
        return failure("Invalid device: \(rest[1])")
      }
      if state != "Shutdown" {
        return CommandResult(
          status: 164,
          stderr: Data("Unable to erase contents and settings in current state: \(state)".utf8))
      }
      return CommandResult(status: 0)
    case "delete" where rest.count == 2:
      if let managementFailure {
        return CommandResult(status: 1, stderr: Data(managementFailure.utf8))
      }
      guard stateOf(rest[1], token: token) != nil else {
        return failure("Invalid device: \(rest[1])")
      }
      if token.isEmpty {
        devices.removeAll { $0.udid == rest[1] }
      } else {
        sets[token]?.removeAll { $0.udid == rest[1] }
      }
      return CommandResult(status: 0)
    case "clone" where rest.count == 3:
      if let cloneFailure { return CommandResult(status: 1, stderr: Data(cloneFailure.utf8)) }
      guard let source = deviceNamed(rest[1], token: token) else {
        return failure("Invalid device: \(rest[1])")
      }
      guard !cloneUDIDs.isEmpty else { return failure("no clone UDID queued") }
      let udid = cloneUDIDs.removeFirst()
      var copy = source
      copy.udid = udid
      copy.name = rest[2]
      copy.state = "Shutdown"
      if let cloneIntoSet {
        sets[cloneIntoSet, default: []].append(copy)
      } else if token.isEmpty {
        devices.append(copy)
      } else {
        sets[token, default: []].append(copy)
      }
      if let dataRoot {
        try? FileManager.default.copyItem(
          atPath: "\(dataRoot)/\(source.udid)", toPath: "\(dataRoot)/\(udid)")
      }
      return CommandResult(status: 0, stdout: Data((cloneOutput ?? udid + "\n").utf8))
    case "list" where rest == ["list", "runtimes", "-j"]:
      let runtimes = runtimeRoots.map { ["identifier": $0.key, "runtimeRoot": $0.value] }
      let data = try! JSONSerialization.data(withJSONObject: ["runtimes": runtimes])
      return CommandResult(status: 0, stdout: data)
    case "spawn" where rest.count >= 4 && rest[2] == "launchctl":
      return launchctl(udid: rest[1], token: token, Array(rest.dropFirst(3)))
    default:
      return nil
    }
  }

  /// Labels loaded in a freshly booted simulator.
  public static var defaultLoaded: Set<String> { [] }

  private func launchctl(udid: String, token: String, _ args: [String]) -> CommandResult? {
    guard stateOf(udid, token: token) == "Booted" else {
      return CommandResult(status: 1, stderr: Data("Unable to spawn: not booted".utf8))
    }
    switch args[0] {
    case "list":
      var text = "PID\tStatus\tLabel\n"
      for label in (loaded[udid] ?? []).sorted() { text += "-\t0\t\(label)\n" }
      return CommandResult(status: 0, stdout: Data(text.utf8))
    case "disable", "enable", "bootout":
      guard args.count == 2, args[1].hasPrefix("system/") else { return nil }
      let label = String(args[1].dropFirst("system/".count))
      if let fail = failTransition?(args[0], label) { return fail }
      switch args[0] {
      case "disable": disabled[udid, default: []].insert(label)
      case "enable": disabled[udid, default: []].remove(label)
      default:
        if loaded[udid]?.remove(label) == nil {
          return CommandResult(status: 3, stderr: Data("No such process".utf8))
        }
      }
      return CommandResult(status: 0)
    case "unload" where args.count >= 3 && args[1] == "-w":
      for path in args.dropFirst(2) {
        guard let label = plistLabels[path] else { continue }
        if let fail = failTransition?("unload", label) {
          _ = fail
          continue
        }
        disabled[udid, default: []].insert(label)
        loaded[udid]?.remove(label)
      }
      return CommandResult(status: 0)
    case "load" where args.count >= 3 && args[1] == "-w":
      // Lifts each job's override and loads it, unless the test makes it fail.
      for path in args.dropFirst(2) {
        guard let label = plistLabels[path] else { continue }
        if failTransition?("load", label) != nil { continue }
        disabled[udid, default: []].remove(label)
        loaded[udid, default: []].insert(label)
      }
      return CommandResult(status: 0)
    case "bootstrap" where args.count == 3 && args[1] == "system":
      guard let label = plistLabels[args[2]] else { return CommandResult(status: 113) }
      if failTransition?("bootstrap", label) != nil { return CommandResult(status: 5) }
      if disabled[udid]?.contains(label) == true { return CommandResult(status: 5) }
      loaded[udid, default: []].insert(label)
      return CommandResult(status: 0)
    default:
      return nil
    }
  }

  private func deviceNamed(_ udid: String, token: String) -> FakeDevice? {
    (token.isEmpty ? devices : (sets[token] ?? [])).first { $0.udid == udid }
  }

  private func plutil(_ args: [String]) -> CommandResult {
    // plutil -extract Label raw -o - <path>
    guard args.count == 6, let label = plistLabels[args[5]] else {
      return CommandResult(status: 1, stderr: Data("plutil: no such file".utf8))
    }
    return CommandResult(status: 0, stdout: Data((label + "\n").utf8))
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
        "isAvailable": device.isAvailable,
        "dataPath": emptyDataPath ? "" : "\(dataRoot ?? "/fake")/\(device.udid)/data",
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
