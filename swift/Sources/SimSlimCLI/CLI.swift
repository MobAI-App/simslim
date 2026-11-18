// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit

/// The simslim command line, with output and the command runner injected so every
/// command can be exercised without a terminal or a simulator.
public struct CLI {
  public typealias Sink = @Sendable (String) -> Void

  public var version: String
  public var environment: [String: String]
  public var runner: CommandRunning
  /// Where simulators' launchd disable overrides live on the host; tests redirect it.
  public var storeRoot: String
  /// Whose `Library/Developer` holds the device sets `watch` observes.
  public var home: String
  /// Whether `top` may draw its live screen; false sends it to one-shot output.
  public var isInteractive: @Sendable () -> Bool
  /// Set by Ctrl-C; `watch` and `top` run until it is.
  public var interrupt: InterruptFlag
  /// Where `profile` reads its prompts and keys; nil uses the terminal.
  var wizardInput: WizardInput?
  public var stdout: Sink
  public var stderr: Sink

  public init(
    version: String = simslimVersion,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    runner: CommandRunning = SystemCommandRunner(),
    storeRoot: String = "/private/var/tmp",
    home: String = NSHomeDirectory(),
    isInteractive: @escaping @Sendable () -> Bool = {
      isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
    },
    interrupt: InterruptFlag = InterruptFlag(),
    stdout: @escaping Sink,
    stderr: @escaping Sink
  ) {
    self.version = version
    self.environment = environment
    self.runner = runner
    self.storeRoot = storeRoot
    self.home = home
    self.isInteractive = isInteractive
    self.interrupt = interrupt
    self.stdout = stdout
    self.stderr = stderr
  }

  /// Everything a command needs, after the global options are applied.
  struct Context {
    var simctl: Simctl
    var bootTimeout: TimeInterval
    var parsed: ParsedArguments
    var home: String
    var isInteractive: Bool
    var interrupt: InterruptFlag
    var wizardInput: WizardInput
    var stdout: Sink
    var stderr: Sink
  }

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
    "boot": [.bool("json", onlyOnce: true)],
    "shutdown": [.bool("json", onlyOnce: true)],
    "on": [
      .string("profile"), .string("except"), .string("keep"), .bool("no-reboot"),
      .bool("preserve-boot-state"),
    ],
    "off": [.bool("preserve-boot-state")],
    "profile": [],
    "clone": [.bool("json", onlyOnce: true)],
    "repair-clone": [.bool("json", onlyOnce: true)],
    "top": [.bool("json", onlyOnce: true)],
    "size": [.bool("json", onlyOnce: true)],
    "disk-categories": [.bool("json", onlyOnce: true)],
    "disk-plan": [.bool("json", onlyOnce: true)],
    "disk-clean": [
      .bool("json", onlyOnce: true), .string("categories"), .bool("confirm"),
      .bool("preserve-boot-state"),
    ],
    "watch": [
      .bool("json"), .string("profile"), .string("except"), .string("keep"), .string("interval"),
    ],
    "rename": [.bool("json", onlyOnce: true)],
    "erase": [.bool("json", onlyOnce: true)],
    "delete": [.bool("json", onlyOnce: true)],
    "enable": [.bool("json", onlyOnce: true), .string("save")],
    "disable": [.bool("json", onlyOnce: true), .string("save")],
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
    simctl.storeRoot = storeRoot
    let bootTimeout = try applyGlobalOptions(parsed, to: &simctl)
    let context = Context(
      simctl: simctl, bootTimeout: bootTimeout, parsed: parsed, home: home,
      isInteractive: isInteractive(), interrupt: interrupt,
      wizardInput: wizardInput ?? .terminal(write: stderr),
      stdout: stdout, stderr: stderr)

    switch command {
    case "list": return try cmdList(context)
    case "profiles": return try cmdProfiles(context)
    case "status": return try cmdStatus(context)
    case "verify": return try cmdVerify(context)
    case "doctor": return try cmdDoctor(context)
    case "measure": return try cmdMeasure(context)
    case "boot": return try cmdBoot(context)
    case "shutdown": return try cmdShutdown(context)
    case "on": return try cmdOn(context)
    case "off": return try cmdOff(context)
    case "clone": return try cmdClone(context)
    case "repair-clone": return try cmdRepairClone(context)
    case "rename": return try cmdRename(context)
    case "erase": return try cmdErase(context)
    case "delete": return try cmdDelete(context)
    case "profile": return try cmdProfile(context)
    case "top": return try cmdTop(context)
    case "size": return try cmdSize(context)
    case "disk-categories": return try cmdDiskCategories(context)
    case "disk-plan": return try cmdDiskPlan(context)
    case "disk-clean": return try cmdDiskClean(context)
    case "watch": return try cmdWatch(context)
    case "enable": return try cmdEnable(context)
    case "disable": return try cmdDisable(context)
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
