// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// The offline route wrote the store but the booted device did not come up in the
/// desired state. The store is an undocumented CoreSimulator detail, so a runtime
/// is always free to ignore it: callers treat this as "take the supported path
/// instead", never as a failure.
struct OfflineIneffective: Error {
  var reason: String
}

/// How many `simctl spawn launchctl` transitions run at once. Overrides are
/// independent launchd writes, so they parallelize, and a small pool hides most
/// of the per-spawn latency without hammering a simulator still settling after
/// its first boot.
let spawnWorkers = 8

/// How many times `applyDelta` walks the remaining labels. Disables are
/// persistent, so each pass only retries what earlier passes failed.
let applyPasses = 3

/// launchctl's exit status when the service to boot out is not loaded ("No such
/// process"), which is already the state a live disable wants.
let bootoutGone: Int32 = 3

/// What a disable does to the running service.
enum DisableAction: Equatable {
  /// `launchctl disable` only: takes effect at the next boot.
  case overrideOnly
  /// `disable` then `bootout`: the daemon stops now and cannot respawn.
  case liveStop
}

/// The managed labels that differ between `after` and `desired`.
func countLost(after: Set<String>, desired: Set<String>, managed: Set<String>) -> Int {
  let moves = delta(current: after, desired: desired, managed: managed)
  return moves.toDisable.count + moves.toEnable.count
}

private final class PassResults: @unchecked Sendable {
  struct Transition: Sendable {
    var action: String  // "disable", "enable" or "bootout" (live stop)
    var label: String
  }

  private let lock = NSLock()
  private(set) var failed: [Transition] = []
  private(set) var failures: [String] = []
  private(set) var done: Int
  let total: Int
  private let reporter: Reporter?

  init(done: Int, total: Int, reporter: Reporter?) {
    self.done = done
    self.total = total
    self.reporter = reporter
  }

  func record(_ transition: Transition, error: String?) {
    lock.lock()
    defer { lock.unlock() }
    if let error {
      failed.append(transition)
      failures.append(error)
      return
    }
    done += 1
    if done == total || done % 20 == 0 { report(reporter, "  \(done)/\(total) services updated") }
  }
}

extension Simctl {
  // MARK: - Per-label transitions

  /// `disable`/`enable`/`bootout` of one label, inside the simulator.
  private func launchctl(set: String, udid: String, verb: String, label: String) throws
    -> CommandResult
  {
    try exec(
      .xcrun, simctlArgs(set: set, ["spawn", udid, "launchctl", verb, "system/\(label)"]),
      timeout: spawnTimeout)
  }

  private func failureText(_ verb: String, _ label: String, _ result: CommandResult) -> String {
    let reason =
      result.timedOut ? "timed out after \(Int(spawnTimeout))s" : "exit status \(result.status)"
    return "\(verb) \(label): \(reason): \(result.combinedText)"
  }

  /// Runs one transition; returns nil on success or the failure text.
  private func runTransition(set: String, udid: String, action: String, label: String) -> String? {
    let verb = action == "bootout" ? "disable" : action
    do {
      let result = try launchctl(set: set, udid: udid, verb: verb, label: label)
      if !result.succeeded { return failureText(verb, label, result) }
      if action != "bootout" { return nil }
      let out = try launchctl(set: set, udid: udid, verb: "bootout", label: label)
      if !out.succeeded && !(out.status == bootoutGone && !out.timedOut) {
        return failureText("bootout", label, out)
      }
      return nil
    } catch {
      return "\(verb) \(label): \(error.localizedDescription)"
    }
  }

  /// Disables then enables the given labels. Each transition is its own
  /// `simctl spawn launchctl`, run through a pool of `spawnWorkers`. A non-zero
  /// exit is a real failure; failures are collected and retried on later passes
  /// rather than aborting the whole profile.
  func applyDelta(
    set: String, udid: String, toDisable: [String], toEnable: [String],
    disableAction: DisableAction, reporter: Reporter?
  ) throws {
    typealias Transition = PassResults.Transition
    var pending: [Transition] = []
    for label in toDisable {
      pending.append(
        Transition(action: disableAction == .liveStop ? "bootout" : "disable", label: label))
    }
    for label in toEnable { pending.append(Transition(action: "enable", label: label)) }
    let total = pending.count
    var done = 0
    var failures: [String] = []

    var pass = 1
    while pass <= applyPasses && !pending.isEmpty {
      if pass > 1 {
        report(
          reporter, "  retrying \(pending.count) failed services (pass \(pass)/\(applyPasses))...")
        // Give a launchd that refused the spawns a moment before asking again.
        if !retryDelays.isEmpty, !deadlineExpired {
          pause(retryDelays[min(pass - 2, retryDelays.count - 1)])
        }
      }
      let results = PassResults(done: done, total: total, reporter: reporter)
      let slots = DispatchSemaphore(value: spawnWorkers)
      let group = DispatchGroup()
      for transition in pending {
        if deadlineExpired { break }
        slots.wait()
        group.enter()
        DispatchQueue.global().async {
          defer {
            slots.signal()
            group.leave()
          }
          let error = self.runTransition(
            set: set, udid: udid, action: transition.action, label: transition.label)
          results.record(transition, error: error)
        }
      }
      group.wait()
      done = results.done
      failures = results.failures
      if deadlineExpired {
        throw SimSlimError(
          "\(total - done)/\(total) launchctl transitions incomplete: \(contextError)")
      }
      pending = results.failed
      pass += 1
    }
    if !pending.isEmpty {
      throw SimSlimError(
        "\(pending.count)/\(total) launchctl transitions failed after \(applyPasses) passes: "
          + failures.joined(separator: "; "))
    }
  }

  // MARK: - ensure

  private func minimumPersistentMessage(_ device: Device) -> String {
    "\(device.runtimeName) runtime cannot persist launchd disable overrides across reboot; "
      + "simslim requires \(device.platformName) \(device.minimumPersistentVersion) or newer, "
      + "or `simslim on --no-reboot` to slim the current boot session only"
  }

  /// Brings the device to exactly the desired disabled state and boots it. A
  /// non-empty profile is rejected before anything is booted or changed on
  /// runtimes without persistent overrides. On a runtime that persists them the
  /// device takes the far cheaper offline route, whatever state it starts in.
  /// Returns whether anything changed.
  @discardableResult
  public func ensure(
    set: String, udid: String, desired requested: Set<String>, reporter: Reporter? = nil
  ) throws -> Bool {
    var device = try findDevice(udid: udid, set: set)
    let desired = desiredForDevice(device, requested)
    let persistent = device.supportsPersistentOverrides
    if !desired.isEmpty && !persistent { throw SimSlimError(minimumPersistentMessage(device)) }
    let managed = Catalog.managedSet

    // A shut-down device can be reconfigured by writing the overrides
    // launchd_sim reads when it starts, which skips both the per-label
    // spawns and the reboot that would apply them.
    let booted = device.state == "Booted"
    if booted && persistent {
      // `simctl list` says Booted from the moment the boot starts, so wait for
      // launchd to be up before asking it anything.
      try bootAndWait(set: set, udid: udid)
      // An override only takes effect at the next boot, so a booted device
      // already owes a shutdown and a boot. Spending them up front makes it a
      // shut-down device and lets the store replace every launchctl spawn.
      let live = try readDisabled(set: set, udid: udid)
      let moves = delta(current: live, desired: desired, managed: managed)
      if moves.toDisable.isEmpty && moves.toEnable.isEmpty { return false }
      report(reporter, "Shutting the simulator down to reconfigure it offline...")
      do {
        try shutdown(set: set, udid: udid)
      } catch {
        throw SimSlimError("shutdown before reconfigure: \(error.localizedDescription)")
      }
      try waitShutdown(set: set, udid: udid)
      device.state = "Shutdown"
    }
    if device.state == "Shutdown" && persistent {
      do {
        let changed = try ensureOffline(
          set: set, udid: udid, desired: desired, reporter: reporter)
        // A device that started booted only gets here with a real delta.
        return changed || booted
      } catch is OfflineIneffective {
        report(
          reporter,
          "Could not apply the changes while the simulator was off; reconfiguring it while booted instead..."
        )
      }
    }

    report(reporter, "Booting the simulator (a first boot can take up to a minute)...")
    try bootAndWait(set: set, udid: udid)
    let current = try readDisabled(set: set, udid: udid)
    let moves = delta(current: current, desired: desired, managed: managed)
    if moves.toDisable.isEmpty && moves.toEnable.isEmpty { return false }
    if !moves.toDisable.isEmpty {
      report(reporter, "Disabling \(moves.toDisable.count) background services...")
    }
    if !moves.toEnable.isEmpty {
      report(reporter, "Re-enabling \(moves.toEnable.count) background services...")
    }
    try applyDelta(
      set: set, udid: udid, toDisable: moves.toDisable, toEnable: moves.toEnable,
      disableAction: .overrideOnly, reporter: reporter)
    report(reporter, "Rebooting the simulator to apply the changes...")
    do {
      try shutdown(set: set, udid: udid)
    } catch {
      throw SimSlimError("shutdown before reboot: \(error.localizedDescription)")
    }
    try waitShutdown(set: set, udid: udid)
    try bootAndWait(set: set, udid: udid)
    let after = try readDisabled(set: set, udid: udid)
    let lost = countLost(after: after, desired: desired, managed: managed)
    if lost > 0 {
      throw SimSlimError(
        "the disable overrides did not survive the reboot (\(lost) of \(moves.toDisable.count + moves.toEnable.count) changes lost)"
      )
    }
    return true
  }

  /// Reaches the desired state on a shut-down device by writing its launchd
  /// overrides directly, then boots it once, already slim. The state is read back
  /// from the booted device rather than trusted.
  func ensureOffline(set: String, udid: String, desired: Set<String>, reporter: Reporter?) throws
    -> Bool
  {
    let store = DisabledStore(root: storeRoot)
    let managed = Catalog.managedSet
    let current: Set<String>
    do {
      current = try store.readDisabled(udid: udid)
    } catch {
      throw OfflineIneffective(reason: error.localizedDescription)
    }
    let moves = delta(current: current, desired: desired, managed: managed)
    let changed = !moves.toDisable.isEmpty || !moves.toEnable.isEmpty
    if changed {
      report(
        reporter,
        "Reconfiguring \(moves.toDisable.count + moves.toEnable.count) background services while the simulator is off..."
      )
      do {
        try store.write(udid: udid, toDisable: moves.toDisable, toEnable: moves.toEnable)
      } catch {
        throw OfflineIneffective(reason: error.localizedDescription)
      }
    }
    report(reporter, "Booting the simulator (a first boot can take up to a minute)...")
    try bootAndWait(set: set, udid: udid)
    let after = try readDisabled(set: set, udid: udid)
    let lost = countLost(after: after, desired: desired, managed: managed)
    if lost > 0 {
      throw OfflineIneffective(
        reason:
          "\(lost) of \(moves.toDisable.count + moves.toEnable.count) offline overrides were not honoured at boot"
      )
    }
    return changed
  }

  /// Disables the profile's daemons and boots the device slim.
  @discardableResult
  public func enableSlim(
    set: String, udid: String, profile: Profile, reporter: Reporter? = nil
  ) throws -> Bool {
    try ensure(set: set, udid: udid, desired: profile.desired(), reporter: reporter)
  }

  /// Re-enables every managed daemon, returning the device to stock.
  @discardableResult
  public func disableSlim(set: String, udid: String, reporter: Reporter? = nil) throws -> Bool {
    try ensure(set: set, udid: udid, desired: [], reporter: reporter)
  }

  // MARK: - No-reboot

  /// Slims the running boot session without a reboot: each daemon the profile
  /// disables is booted out of launchd, and the override keeps launchd from
  /// respawning it. Works on every runtime, but without persistent overrides the
  /// simulator comes back stock at its next boot. Only moves toward more-disabled:
  /// managed labels disabled beyond the profile are left alone.
  @discardableResult
  public func enableSlimNoReboot(
    set: String, udid: String, profile: Profile, reporter: Reporter? = nil
  ) throws -> Bool {
    let device = try findDevice(udid: udid, set: set)
    let desired = profile.desired(for: device)
    report(reporter, "Booting the simulator (a first boot can take up to a minute)...")
    try bootAndWait(set: set, udid: udid)
    let current = try readDisabled(set: set, udid: udid)
    let managed = Catalog.managedSet
    let moves = delta(current: current, desired: desired, managed: managed)
    if !moves.toEnable.isEmpty {
      report(
        reporter,
        "Leaving \(moves.toEnable.count) services disabled beyond this profile; only `simslim off` re-enables them."
      )
    }
    // Check every profiled label, not just those without an override: an
    // override says nothing about whether the job is still loaded. Labels that
    // are both disabled and unloaded are skipped, so the command is idempotent.
    let changed = !moves.toDisable.isEmpty
    let labels = desired.filter { managed.contains($0) }.sorted()
    report(reporter, "Stopping \(labels.count) background services for this boot session...")
    let remaining = unloadInBatch(
      set: set, udid: udid, runtimeID: device.runtimeID, labels: labels, reporter: reporter)
    try applyDelta(
      set: set, udid: udid, toDisable: remaining, toEnable: [], disableAction: .liveStop,
      reporter: reporter)
    let after = try readDisabled(set: set, udid: udid)
    let missing = delta(current: after, desired: desired, managed: managed).toDisable
    if !missing.isEmpty {
      throw SimSlimError("\(missing.count) of \(labels.count) disable overrides did not take")
    }
    return changed
  }

  /// Disables and unloads the labels whose job plist it can find with one
  /// `launchctl unload -w` per chunk, then reads the state back and returns what
  /// still needs the per-label disable and bootout. Anything that goes wrong here
  /// only means more labels take the per-label path.
  func unloadInBatch(
    set: String, udid: String, runtimeID: String, labels: [String], reporter: Reporter?
  ) -> [String] {
    if runtimeID.isEmpty { return labels }
    guard let root = try? runtimeRoot(runtimeID: runtimeID) else { return labels }
    // Only what is still enabled or loaded needs stopping, so an already-slim
    // device spawns no unload and does not report work it did not do.
    guard let pending = try? stopState(set: set, udid: udid, labels: labels) else {
      return labels
    }
    if pending.isEmpty {
      report(reporter, "  all \(labels.count) services were already stopped")
      return []
    }
    let plists = launchdJobPlists(
      root: root, labels: pending, plistLabel: { try self.readPlistLabel(path: $0) })
    if plists.isEmpty { return pending }
    let paths = pending.compactMap { plists[$0] }
    unloadJobs(set: set, udid: udid, paths: paths)
    guard let rest = try? stopState(set: set, udid: udid, labels: pending) else { return pending }
    report(
      reporter, "  \(pending.count - rest.count)/\(pending.count) services stopped in one batch")
    return rest
  }
}
