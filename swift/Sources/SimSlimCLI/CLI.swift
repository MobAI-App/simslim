import Foundation
import SimSlimKit

/// The simslim command line, with output and the command runner injected so every
/// command can be exercised without a terminal or a simulator.
public struct CLI {
  public typealias Sink = @Sendable (String) -> Void

  public var version: String
  public var environment: [String: String]
  public var runner: CommandRunning
  public var stdout: Sink
  public var stderr: Sink

  public init(
    version: String = simslimVersion,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runner: CommandRunning = SystemCommandRunner(),
    stdout: @escaping Sink,
    stderr: @escaping Sink
  ) {
    self.version = version
    self.environment = environment
    self.runner = runner
    self.stdout = stdout
    self.stderr = stderr
  }

  /// Everything a command needs, after the global options are applied.
  struct Context {
    var simctl: Simctl
    var bootTimeout: TimeInterval
    var parsed: ParsedArguments
    var stdout: Sink
    var stderr: Sink
  }

  /// Commands that exist in the Go CLI but are not in the Swift port yet.
  static let notYetPorted: Set<String> = [
    "profile", "on", "off", "enable", "disable", "watch", "top", "size", "disk-categories",
    "disk-plan", "disk-clean", "clone", "repair-clone", "rename", "boot", "shutdown", "erase",
    "delete",
  ]

  static let globalSpecs: [FlagSpec] = [
    .string("set"), .string("boot-timeout"), .string("spawn-timeout"),
  ]

  static let commandSpecs: [String: [FlagSpec]] = [
    "list": [.bool("json", onlyOnce: true), .bool("booted")],
    "profiles": [.bool("json", onlyOnce: true)],
    "status": [.bool("json", onlyOnce: true), .bool("dropped")],
    "verify": [
      .bool("json", onlyOnce: true), .string("profile"), .string("except"), .string("keep"),
    ],
    "doctor": [.bool("json", onlyOnce: true), .string("requires"), .bool("list")],
    "measure": [.bool("json", onlyOnce: true)],
  ]

  /// Runs the command line (without the program name) and returns the exit status.
  public func run(_ arguments: [String]) -> Int32 {
    guard let first = arguments.first else {
      stdout(usageText)
      return 2
    }
    switch first {
    case "-v", "--version", "version":
      stdout("simslim \(version)\n")
      return 0
    case "-h", "--help", "help":
      stdout(usageText)
      return 0
    default:
      break
    }

    do {
      return try dispatch(arguments)
    } catch let error as SimSlimError {
      stderr("simslim: \(error.message)\n")
      return 1
    } catch {
      stderr("simslim: \(error.localizedDescription)\n")
      return 1
    }
  }

  private func dispatch(_ arguments: [String]) throws -> Int32 {
    // Global options may precede the command name.
    var index = 0
    var leading: [String] = []
    while index < arguments.count, arguments[index].hasPrefix("-") {
      leading.append(arguments[index])
      let name = arguments[index].drop(while: { $0 == "-" })
      index += 1
      if !name.contains("="), CLI.globalSpecs.first(where: { $0.name == name }) != nil,
        index < arguments.count
      {
        leading.append(arguments[index])
        index += 1
      }
    }
    guard index < arguments.count else {
      // Only global options were given.
      _ = try parseArguments(leading, specs: CLI.globalSpecs)
      stdout(usageText)
      return 2
    }

    let command = arguments[index]
    let rest = leading + Array(arguments[(index + 1)...])

    if CLI.notYetPorted.contains(command) {
      throw SimSlimError(
        "\"\(command)\" is not available in the Swift port yet; use the Go CLI for it")
    }
    guard let specs = CLI.commandSpecs[command] else {
      stderr("unknown command \"\(command)\"\n\n")
      stdout(usageText)
      return 2
    }

    let parsed: ParsedArguments
    do {
      parsed = try parseArguments(rest, specs: specs + CLI.globalSpecs)
    } catch let error as SimSlimError where error.message == "flag needs an argument: --set" {
      throw SimSlimError("--set requires a device set name (such as `testing`) or a path")
    }

    var simctl = Simctl(runner: runner)
    let bootTimeout = try applyGlobalOptions(parsed, to: &simctl)
    let context = Context(
      simctl: simctl, bootTimeout: bootTimeout, parsed: parsed, stdout: stdout, stderr: stderr)

    switch command {
    case "list": return try cmdList(context)
    case "profiles": return try cmdProfiles(context)
    case "status": return try cmdStatus(context)
    case "verify": return try cmdVerify(context)
    case "doctor": return try cmdDoctor(context)
    case "measure": return try cmdMeasure(context)
    default: preconditionFailure("command \(command) has specs but no handler")
    }
  }

  /// Applies --set, --boot-timeout and --spawn-timeout (each also settable from
  /// the environment, for the two timeouts) and returns the boot timeout.
  private func applyGlobalOptions(_ parsed: ParsedArguments, to simctl: inout Simctl) throws
    -> TimeInterval
  {
    if parsed.has("set") {
      let sets = splitList(parsed.string("set"))
      if sets.isEmpty {
        throw SimSlimError("--set requires a device set name (such as `testing`) or a path")
      }
      for set in sets { simctl.registerDeviceSet(set) }
    }

    func duration(flag: String, env: String, fallback: TimeInterval) throws -> TimeInterval {
      let raw = parsed.has(flag) ? parsed.string(flag) : (environment[env] ?? "")
      if raw.isEmpty { return fallback }
      let value: TimeInterval
      do {
        value = try parseGoDuration(raw)
      } catch {
        throw SimSlimError(
          "invalid value \"\(raw)\" for flag -\(flag): \((error as? SimSlimError)?.message ?? "parse error")"
        )
      }
      if value <= 0 {
        let example = flag == "boot-timeout" ? "15m" : "2m"
        throw SimSlimError("--\(flag) must be a positive duration (such as `\(example)`)")
      }
      return value
    }

    simctl.spawnTimeout = try duration(
      flag: "spawn-timeout", env: "SIMSLIM_SPAWN_TIMEOUT", fallback: simctl.spawnTimeout)
    return try duration(flag: "boot-timeout", env: "SIMSLIM_BOOT_TIMEOUT", fallback: 600)
  }
}

func oneUDID(_ positionals: [String]) throws -> String {
  guard positionals.count == 1 else {
    throw SimSlimError("expected exactly one simulator UDID (see `simslim list`)")
  }
  return positionals[0]
}
