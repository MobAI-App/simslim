import Foundation

/// A CoreSimulator device set: the default one, Xcode's `testing` set, or a
/// custom path named with `--set`.
public struct DeviceSet: Equatable, Sendable {
  /// "" for the default set; otherwise passed to `simctl --set`.
  public let token: String
  public let name: String
}

/// The only place that shells out to `xcrun simctl`.
public struct Simctl: Sendable {
  public var runner: CommandRunning
  /// Sets named with `--set`, beyond the always-scanned default and `testing`.
  public private(set) var extraSets: [String] = []
  /// Bounds one `simctl spawn launchctl` call. A first boot can saturate the
  /// simulator, so a single spawn can stall for minutes; a per-spawn bound turns
  /// that into a retryable failure instead of an unbounded wait.
  public var spawnTimeout: TimeInterval = 120
  /// Pauses between attempts to read a simulator's launchd state. Right after a
  /// boot, and while a reboot tears the old session down, launchd_sim refuses
  /// spawns for a few seconds (error 124, "Domain is tearing down").
  public var retryDelays: [TimeInterval] = [1, 2, 4, 8]
  public var sleep: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
  /// Where launchd_sim keeps each device's disable overrides (a test redirects it).
  public var storeRoot = "/private/var/tmp"
  /// An overall bound for the operation in progress, standing in for Go's context
  /// deadline: every command is capped to what is left of it, and nothing starts
  /// once it has passed.
  public var deadline: Date?
  /// Asked before every command and wait: true once the operation was cancelled
  /// (a watched device shut down, or the user pressed Ctrl-C). A command already
  /// running finishes or times out; nothing new starts.
  public var cancelled: (@Sendable () -> Bool)?
  /// The clock the deadline is read from (a test replaces it).
  public var now: @Sendable () -> Date = { Date() }

  public init(runner: CommandRunning = SystemCommandRunner()) {
    self.runner = runner
  }

  // MARK: - Running commands

  /// Sleeps, but never past the deadline, so an expired operation wakes at once.
  func pause(_ seconds: TimeInterval) {
    var length = seconds
    if let deadline { length = min(length, max(0, deadline.timeIntervalSince(now()))) }
    sleep(length)
  }

  /// True once the operation is over, by deadline or by cancellation.
  var deadlineExpired: Bool {
    cancelled?() == true || (deadline.map { now() >= $0 } ?? false)
  }

  /// What Go's context reports for the reason the operation is over.
  var contextError: String {
    cancelled?() == true ? "context canceled" : "context deadline exceeded"
  }

  /// Runs a command under the operation deadline. The per-call `timeout` is
  /// capped to what is left of the deadline; a command killed by the deadline
  /// (rather than by its own `timeout`) is an error.
  func exec(_ executable: Executable, _ arguments: [String], timeout: TimeInterval? = nil) throws
    -> CommandResult
  {
    var limit = timeout
    if cancelled?() == true { throw SimSlimError("context canceled") }
    if let deadline {
      let left = deadline.timeIntervalSince(now())
      if left <= 0 { throw SimSlimError("context deadline exceeded") }
      limit = min(limit ?? left, left)
    }
    let result = try runner.run(executable, arguments, timeout: limit)
    if result.timedOut, deadlineExpired { throw SimSlimError(contextError) }
    return result
  }

  // MARK: - Device sets

  public var knownSets: [DeviceSet] {
    [DeviceSet(token: "", name: "default"), DeviceSet(token: "testing", name: "testing")]
      + extraSets.map { DeviceSet(token: $0, name: $0) }
  }

  /// Adds a `--set` value to the scanned sets, ignoring one that duplicates a
  /// known token.
  public mutating func registerDeviceSet(_ value: String) {
    if knownSets.contains(where: { $0.token == value }) { return }
    extraSets.append(value)
  }

  func token(forSet name: String) -> String {
    knownSets.first { $0.name == name }?.token ?? ""
  }

  /// `--set` must precede the subcommand.
  func simctlArgs(set name: String, _ sub: [String]) -> [String] {
    Simctl.simctlArgs(token: token(forSet: name), sub)
  }

  static func simctlArgs(token: String, _ sub: [String]) -> [String] {
    token.isEmpty ? ["simctl"] + sub : ["simctl", "--set", token] + sub
  }

  // MARK: - Listing

  private struct ListOutput: Decodable {
    struct Entry: Decodable {
      var udid: String?
      var name: String?
      var state: String?
      var isAvailable: Bool?
      var dataPath: String?
    }
    var devices: [String: [Entry]]
  }

  func listDevices(in set: DeviceSet) throws -> [Device] {
    let args = Simctl.simctlArgs(token: set.token, ["list", "devices", "-j"])
    let result: CommandResult
    do {
      result = try exec(.xcrun, args)
    } catch {
      throw SimSlimError("simctl list: \(error.localizedDescription)")
    }
    guard result.succeeded else {
      throw Simctl.listError(status: result.status, stderr: result.stderrText)
    }
    let parsed: ListOutput
    do {
      parsed = try JSONDecoder().decode(ListOutput.self, from: result.stdout)
    } catch {
      throw SimSlimError("parse simctl list: \(error.localizedDescription)")
    }

    var devices: [Device] = []
    for runtime in parsed.devices.keys.sorted() {
      guard let (platform, version) = Simctl.parseRuntime(runtime) else { continue }
      for entry in parsed.devices[runtime] ?? [] {
        // Like the Go tool, an entry without isAvailable is treated as unavailable.
        guard entry.isAvailable == true, let udid = entry.udid else { continue }
        devices.append(
          Device(
            udid: udid, name: entry.name ?? "", state: entry.state ?? "", platform: platform,
            osVersion: version, set: set.name, dataPath: entry.dataPath ?? "", runtimeID: runtime))
      }
    }
    return devices
  }

  /// Surfaces xcrun's stderr, and when xcrun cannot find simctl at all (xcode-select
  /// pointing at the Command Line Tools) says how to select a full Xcode.
  static func listError(status: Int32, stderr: String) -> SimSlimError {
    let base = "simctl list: exit status \(status)"
    let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty { return SimSlimError(base) }
    if text.contains("unable to find utility \"simctl\"") {
      return SimSlimError(
        "\(base): \(text) (simctl ships with full Xcode, not the Command Line Tools; "
          + "select one with `sudo xcode-select -s /Applications/Xcode.app`)")
    }
    return SimSlimError("\(base): \(text)")
  }

  /// Lists every available simulator. The default set is mandatory; a secondary
  /// set that cannot be listed (for example, one that does not exist) is skipped.
  public func listDevices() throws -> [Device] {
    var devices: [Device] = []
    for set in knownSets {
      do {
        devices += try listDevices(in: set)
      } catch {
        if set.token.isEmpty { throw error }
      }
    }
    return devices
  }

  /// Accepts only the simulator platforms supported by slimming.
  static func parseRuntime(_ runtime: String) -> (platform: String, version: String)? {
    let prefix = "com.apple.CoreSimulator.SimRuntime."
    guard runtime.hasPrefix(prefix) else { return nil }
    let name = runtime.dropFirst(prefix.count)
    guard let dash = name.firstIndex(of: "-") else { return nil }
    let platform = String(name[..<dash])
    let version = String(name[name.index(after: dash)...])
    if version.isEmpty { return nil }
    let dotted = version.replacingOccurrences(of: "-", with: ".")
    switch platform {
    case "iOS", "tvOS", "watchOS": return (platform, dotted)
    case "xrOS": return ("visionOS", dotted)  // CoreSimulator still names visionOS xrOS
    default: return nil
    }
  }

  /// Finds a simulator by UDID. An empty `set` searches every known set; a
  /// non-empty one looks only there.
  public func findDevice(udid: String, set: String = "") throws -> Device {
    for candidate in knownSets {
      if !set.isEmpty && candidate.name != set { continue }
      let found: [Device]
      do {
        found = try listDevices(in: candidate)
      } catch {
        if candidate.token.isEmpty { throw error }
        continue
      }
      if let device = found.first(where: { $0.udid == udid }) { return device }
    }
    throw SimSlimError("no simulator with udid \(udid)")
  }

  // MARK: - launchd inside a simulator

  /// The labels currently disabled in the device's system domain. A label absent
  /// from the output is enabled.
  public func readDisabled(set: String, udid: String) throws -> Set<String> {
    let output = try readLaunchd(set: set, udid: udid, ["print-disabled", "system"])
    return Simctl.parseDisabled(output)
  }

  /// Runs a read-only launchctl command inside the simulator, each attempt bounded
  /// by `spawnTimeout`. launchd_sim's transient error 124 and an attempt that ran
  /// out of time are retried after each of `retryDelays`; any other failure is
  /// returned at once.
  func readLaunchd(set: String, udid: String, _ args: [String]) throws -> String {
    let arguments = simctlArgs(set: set, ["spawn", udid, "launchctl"] + args)
    var attempt = 0
    while true {
      let result: CommandResult
      do {
        result = try exec(.xcrun, arguments, timeout: spawnTimeout)
      } catch {
        throw SimSlimError("launchctl \(args[0]): \(error.localizedDescription)")
      }
      if result.succeeded { return result.stdoutText }

      let reason =
        result.timedOut
        ? "timed out after \(Int(spawnTimeout))s" : "exit status \(result.status)"
      let message = "launchctl \(args[0]): \(reason): \(result.combinedText)"
      let settling = Simctl.launchdSettling(result) || result.timedOut
      if !settling || attempt >= retryDelays.count || deadlineExpired {
        throw SimSlimError(message)
      }
      pause(retryDelays[attempt])
      attempt += 1
    }
  }

  /// Whether a spawn failed with launchd_sim's error 124, which it answers while
  /// a boot session starts or tears down.
  static func launchdSettling(_ result: CommandResult) -> Bool {
    if result.status == 124 { return true }
    let text = result.stdoutText + result.stderrText
    return text.contains("code=124") || text.contains("Domain is tearing down")
  }

  /// Reads `launchctl print-disabled` lines. Recent launchd prints
  /// `"com.apple.x" => disabled`; older builds print `=> true` / `=> false`.
  static func parseDisabled(_ output: String) -> Set<String> {
    var set = Set<String>()
    for line in output.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
      guard let open = line.firstIndex(of: "\"") else { continue }
      let rest = line[line.index(after: open)...]
      guard let close = rest.firstIndex(of: "\"") else { continue }
      let label = String(rest[..<close])
      guard let arrow = rest[close...].range(of: "=>") else { continue }
      let value = rest[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      if value.hasPrefix("disabled") || value.hasPrefix("true") { set.insert(label) }
    }
    return set
  }
}
