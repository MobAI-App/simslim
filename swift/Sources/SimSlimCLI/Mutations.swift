// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit

// The commands that change simulator state. Each resolves the exact device
// first, so a simctl alias such as `all` can never fan out a boot or a slim.

extension CLI {
  /// A copy of the simctl handle that gives up `seconds` from now.
  private func bounded(_ simctl: Simctl, by seconds: TimeInterval) -> Simctl {
    var copy = simctl
    copy.deadline = copy.now().addingTimeInterval(seconds)
    return copy
  }

  private func progress(_ context: Context) -> Reporter {
    let stderr = context.stderr
    return { stderr($0 + "\n") }
  }

  func cmdBoot(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    let device = try context.simctl.findDevice(udid: udid)
    let result = SimulatorMutationOutput(action: "boot", udid: udid)
    if device.state == "Booted" {
      if json {
        context.stdout(try jsonText(result))
      } else {
        context.stdout("Simulator \(udid) is already booted.\n")
      }
      return 0
    }
    // Booting and waiting for services can take about a minute. Stderr is quiet
    // under --json so a consumer reading a combined stream gets clean JSON.
    if !json { context.stderr("Booting \(udid)...\n") }
    try bounded(context.simctl, by: context.bootTimeout).bootAndWait(
      set: device.set, udid: udid)
    context.stdout(json ? try jsonText(result) : "Booted \(udid).\n")
    return 0
  }

  func cmdShutdown(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    let device = try context.simctl.findDevice(udid: udid)
    let result = SimulatorMutationOutput(action: "shutdown", udid: udid)
    if device.state != "Booted" {
      if json {
        context.stdout(try jsonText(result))
      } else {
        context.stdout("Simulator \(udid) is already shut down.\n")
      }
      return 0
    }
    try bounded(context.simctl, by: Simctl.shutdownTimeout).shutdownAndWait(
      set: device.set, udid: udid)
    context.stdout(json ? try jsonText(result) : "Shut down \(udid).\n")
    return 0
  }

  /// Returns a simulator that started shut down to that state.
  private func returnToShutdown(_ context: Context, set: String, udid: String) throws {
    do {
      try context.simctl.shutdownAndWait(set: set, udid: udid)
    } catch {
      throw SimSlimError("restore original shutdown state: \(error.localizedDescription)")
    }
  }

  /// Runs `operation`, then restores a shut-down state when asked. The restore
  /// happens even when the operation failed, and both failures are reported.
  private func withBootStateRestored(
    _ context: Context, restore: Bool, set: String, udid: String,
    operation: () throws -> Bool
  ) throws -> Bool {
    var changed = false
    var operationError: Error?
    do { changed = try operation() } catch { operationError = error }
    if restore {
      do {
        try returnToShutdown(context, set: set, udid: udid)
      } catch {
        if let operationError {
          throw SimSlimError(
            "\(operationError.localizedDescription); additionally could not restore original shutdown state: \(error.localizedDescription)"
          )
        }
        throw error
      }
    }
    if let operationError { throw operationError }
    return changed
  }

  func cmdOn(_ context: Context) throws -> Int32 {
    let parsed = context.parsed
    let preserve = parsed.bool("preserve-boot-state")
    let noReboot = parsed.bool("no-reboot")
    if noReboot && preserve {
      throw SimSlimError(
        "--no-reboot cannot be combined with --preserve-boot-state: shutting the simulator down discards a no-reboot slim"
      )
    }
    let udid = try oneUDID(parsed.positionals)
    let profile = try buildProfile(
      profilePath: parsed.string("profile"), except: parsed.string("except"),
      keep: parsed.string("keep"))
    // Resolve once: this pins the device's set (routing every simctl call below),
    // fails fast on an unknown UDID, and says whether to restore a shut-down state.
    let device = try context.simctl.findDevice(udid: udid)
    let reporter = progress(context)
    let simctl = bounded(context.simctl, by: context.bootTimeout)
    let count = profile.desired(for: device).count

    if noReboot {
      context.stderr(
        "Slimming \(udid) for this boot session: stopping \(count) background services without a reboot.\n"
      )
      let changed = try simctl.enableSlimNoReboot(
        set: device.set, udid: udid, profile: profile, reporter: reporter)
      context.stdout(
        changed
          ? "Done. Simulator slimmed for this boot session without a reboot.\n"
          : "Already slim. Confirmed every profiled daemon is stopped for this boot session.\n")
      if device.supportsPersistentOverrides {
        context.stdout(
          "The disable overrides are also stored, so the next boot should come up slim; `simslim verify` after a reboot confirms it.\n"
        )
      } else {
        context.stdout(
          "\(device.runtimeName) cannot persist overrides: the simulator returns to stock at its next boot, so re-run this command after every boot.\n"
        )
      }
      return 0
    }

    let startedShutdown = device.state == "Shutdown"
    let originallyShutdown = preserve && startedShutdown
    if startedShutdown {
      context.stderr(
        "Slimming \(udid): disabling \(count) background services while it is off, then booting it slim.\n"
      )
    } else {
      context.stderr(
        "Slimming \(udid): disabling \(count) background services. The simulator will reboot to apply the changes.\n"
      )
    }
    let changed = try withBootStateRestored(
      context, restore: originallyShutdown, set: device.set, udid: udid
    ) {
      try simctl.enableSlim(set: device.set, udid: udid, profile: profile, reporter: reporter)
    }
    if changed {
      if originallyShutdown {
        context.stdout("Done. Simulator reconfigured slim and returned to shutdown.\n")
      } else if startedShutdown {
        context.stdout("Done. Simulator reconfigured slim and booted.\n")
      } else {
        context.stdout("Done. Simulator reconfigured and rebooted slim.\n")
      }
    } else if originallyShutdown {
      context.stdout("Already slim. Original shutdown state restored.\n")
    } else {
      context.stdout("Already slim. Nothing to change.\n")
    }
    return 0
  }

  func cmdOff(_ context: Context) throws -> Int32 {
    let preserve = context.parsed.bool("preserve-boot-state")
    let udid = try oneUDID(context.parsed.positionals)
    let device = try context.simctl.findDevice(udid: udid)
    let startedShutdown = device.state == "Shutdown"
    let originallyShutdown = preserve && startedShutdown
    if startedShutdown {
      context.stderr("Restoring \(udid) to stock while it is off, then booting it.\n")
    } else {
      context.stderr(
        "Restoring \(udid) to stock. The simulator will reboot to apply the changes.\n")
    }
    let reporter = progress(context)
    let simctl = bounded(context.simctl, by: context.bootTimeout)
    let changed = try withBootStateRestored(
      context, restore: originallyShutdown, set: device.set, udid: udid
    ) {
      try simctl.disableSlim(set: device.set, udid: udid, reporter: reporter)
    }
    if changed {
      if originallyShutdown {
        context.stdout("Done. All daemons re-enabled and simulator returned to shutdown.\n")
      } else if startedShutdown {
        context.stdout("Done. All daemons re-enabled and simulator booted.\n")
      } else {
        context.stdout("Done. All daemons re-enabled and simulator rebooted.\n")
      }
    } else if originallyShutdown {
      context.stdout("Already stock. Original shutdown state restored.\n")
    } else {
      context.stdout("Already stock. Nothing to change.\n")
    }
    return 0
  }

  // MARK: - enable / disable

  /// `<udid> [ids...]`, where each ID argument may itself be a comma-separated
  /// list, as in `simslim enable <udid> icloud,photos`.
  private func udidAndIDs(_ args: [String]) throws -> (udid: String, ids: [String]) {
    guard let udid = args.first else {
      throw SimSlimError(
        "expected a simulator UDID (see `simslim list`), then category IDs or launchd labels (see `simslim profiles`)"
      )
    }
    return (udid, args.dropFirst().flatMap { splitList($0) })
  }

  /// Progress goes to stderr, except under --json, where a consumer reading a
  /// combined stream must get clean JSON.
  private func quietIfJSON(_ context: Context) -> Reporter? {
    context.parsed.bool("json") ? nil : progress(context)
  }

  func cmdEnable(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let (udid, ids) = try udidAndIDs(context.parsed.positionals)
    let out = try bounded(context.simctl, by: context.bootTimeout).enableServices(
      udid: udid, ids: ids, save: context.parsed.string("save"),
      reporter: quietIfJSON(context))
    if json {
      context.stdout(try jsonText(out))
      return 0
    }
    if out.live {
      context.stdout("Enabled \(out.labels.count) services on \(udid) without a reboot.\n")
    }
    if !out.notStarted.isEmpty {
      context.stdout(
        "  launchd starts \(out.notStarted.count) of them at the next boot, not in this one: \(out.notStarted.joined(separator: ", "))\n"
      )
    }
    printSaved(context, out)
    return 0
  }

  func cmdDisable(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let (udid, ids) = try udidAndIDs(context.parsed.positionals)
    let out = try bounded(context.simctl, by: context.bootTimeout).disableServices(
      udid: udid, ids: ids, save: context.parsed.string("save"),
      reporter: quietIfJSON(context))
    if json {
      context.stdout(try jsonText(out))
      return 0
    }
    if out.live {
      if out.labels.isEmpty {
        context.stdout("Nothing to stop on \(udid).\n")
      } else {
        context.stdout("Stopped \(out.labels.count) services on \(udid) without a reboot.\n")
      }
    }
    if !out.stillEnabled.isEmpty {
      context.stdout(
        "  \(out.stillEnabled.count) stay enabled for another fully enabled category or the platform: \(out.stillEnabled.joined(separator: ", "))\n"
      )
    }
    printSaved(context, out)
    return 0
  }

  /// Closes enable and disable with what persists: the saved profile, or a
  /// reminder that the next `on` or `watch` pass applies its profile again.
  private func printSaved(_ context: Context, _ out: ServicesOutput) {
    if out.saved.isEmpty {
      context.stdout(
        "This lasts until the next `on` or `watch` pass; pass --save <profile.json> to keep it in a profile.\n"
      )
    } else if out.live {
      context.stdout(
        "Saved to \(out.saved). Apply it later with `simslim on \(out.udid) --profile \(out.saved)`.\n"
      )
    } else {
      context.stdout(
        "Saved to \(out.saved); nothing was applied, the simulator is not booted. Apply it with `simslim on \(out.udid) --profile \(out.saved)`.\n"
      )
    }
  }

  // MARK: - rename / erase / delete

  func cmdRename(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let args = context.parsed.positionals
    guard args.count == 2 else {
      throw SimSlimError("rename expects a simulator UDID and a new name")
    }
    let name = try normalizeSimulatorName(args[1])
    try bounded(context.simctl, by: Simctl.shutdownTimeout).renameDevice(udid: args[0], name: name)
    if json {
      context.stdout(
        try jsonText(SimulatorMutationOutput(action: "rename", udid: args[0], name: name)))
    } else {
      context.stdout("Renamed \(args[0]) to \(goQuote(name)).\n")
    }
    return 0
  }

  func cmdErase(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    try bounded(context.simctl, by: context.bootTimeout).eraseDevice(udid: udid)
    context.stdout(
      json
        ? try jsonText(SimulatorMutationOutput(action: "erase", udid: udid))
        : "Erased simulator \(udid).\n")
    return 0
  }

  func cmdDelete(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    try bounded(context.simctl, by: context.bootTimeout).deleteDevice(udid: udid)
    context.stdout(
      json
        ? try jsonText(SimulatorMutationOutput(action: "delete", udid: udid))
        : "Deleted simulator \(udid).\n")
    return 0
  }
}
