// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit

extension CLI {
  /// The clone budget, and Ctrl-C handling: an interrupt stops the next step, and
  /// the cleanup that deletes an unsafe clone or restores a boot state still runs.
  private func cloneHandle(_ context: Context) -> Simctl {
    context.interrupt.install()
    var simctl = context.simctl
    let interrupt = context.interrupt
    simctl.cancelled = { interrupt.isSet }
    simctl.deadline = simctl.now().addingTimeInterval(
      Simctl.cloneOperationTimeout(bootTimeout: context.bootTimeout))
    return simctl
  }

  private func progressReporter(_ context: Context, quiet: Bool) -> Reporter? {
    if quiet { return nil }
    let stderr = context.stderr
    return { message in stderr(message + "\n") }
  }

  func cmdClone(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let args = context.parsed.positionals
    guard args.count == 2 else {
      throw SimSlimError("clone expects a simulator UDID and a new name")
    }
    let name = try normalizeSimulatorName(args[1])
    let reporter = progressReporter(context, quiet: json)
    let created = try cloneHandle(context).cloneDevice(
      udid: args[0], name: name, home: context.home, restoreTimeout: context.bootTimeout,
      reporter: reporter)
    if json {
      context.stdout(
        try jsonText(
          SimulatorMutationOutput(action: "clone", udid: created, name: name, sourceUdid: args[0])))
    } else {
      context.stdout("Cloned \(args[0]) as \(goQuote(name)) (\(created)).\n")
    }
    return 0
  }

  func cmdRepairClone(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let args = context.parsed.positionals
    guard args.count == 2 else {
      throw SimSlimError("repair-clone expects the source UDID and cloned simulator UDID")
    }
    let reporter = progressReporter(context, quiet: json)
    try cloneHandle(context).repairClonedDevice(
      sourceUDID: args[0], cloneUDID: args[1], home: context.home,
      restoreTimeout: context.bootTimeout, reporter: reporter)
    if json {
      context.stdout(
        try jsonText(
          SimulatorMutationOutput(action: "repair-clone", udid: args[1], sourceUdid: args[0])))
    } else {
      context.stdout(
        "Repaired clone \(args[1]) and verified no links or open files into specified source \(args[0]).\n"
      )
    }
    return 0
  }
}
