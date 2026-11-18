// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

// `clone` and `repair-clone`. CoreSimulator's raw clone carries absolute source
// paths in symlinks and generated registries, so the source stays shut down until
// the copy has been rebased, its app registrations rebuilt, its service profile
// verified, and the running clone audited for open source paths. A clone that
// fails any step is deleted rather than returned as ready.

/// The labels a clone may carry over: only ones simslim is allowed to disable. A
/// source can hold unrelated or obsolete overrides, and cloning must not turn
/// those into managed state or spread an unsafe one.
func desiredCloneDisabled(_ disabled: Set<String>) -> Set<String> {
  disabled.intersection(Catalog.slimmableSet)
}

extension Simctl {
  /// The operation budget for one clone or repair, derived from the boot
  /// timeout like Go's `CloneOperationTimeout`.
  public static func cloneOperationTimeout(bootTimeout: TimeInterval) -> TimeInterval {
    3 * bootTimeout + 2 * Simctl.shutdownTimeout
  }

  /// A handle for cleanup that must still run after the operation was cancelled
  /// or ran out of time, with a fresh budget.
  private func detached(_ seconds: TimeInterval) -> Simctl {
    var copy = self
    copy.cancelled = nil
    copy.deadline = copy.now().addingTimeInterval(seconds)
    return copy
  }

  // MARK: - clone

  /// Clones a booted or shut-down simulator and returns the new UDID. The source
  /// is returned to the boot state it started in, and a clone that cannot be
  /// made independent of it is deleted.
  public func cloneDevice(
    udid: String, name requested: String, home: String, restoreTimeout: TimeInterval,
    reporter: Reporter? = nil
  ) throws -> String {
    let name = try normalizeSimulatorName(requested)
    let (source, sourceData) = try simulatorDataDirectory(udid: udid)
    if source.state != "Booted" && source.state != "Shutdown" {
      throw SimSlimError(
        "simulator must be booted or shutdown before cloning (it is \(source.state))")
    }
    let sourceWasBooted = source.state == "Booted"

    var created: String?
    var failure: Error?
    do {
      created = try cloneBody(
        source: source, sourceData: sourceData, name: name, home: home,
        restoreTimeout: restoreTimeout, reporter: reporter)
    } catch {
      failure = error
    }

    do {
      try detached(restoreTimeout).restoreState(
        set: source.set, udid: udid, booted: sourceWasBooted)
    } catch {
      let restore = error.localizedDescription
      if let failure {
        throw SimSlimError(
          "\(failure.localizedDescription); additionally could not restore the source boot state: \(restore)"
        )
      }
      if let created {
        throw SimSlimError(
          "cloned simulator \(created), but could not restore the source boot state: \(restore)")
      }
      throw SimSlimError("could not restore the source boot state: \(restore)")
    }
    if let failure { throw failure }
    return created ?? ""
  }

  private func cloneBody(
    source: Device, sourceData: String, name: String, home: String, restoreTimeout: TimeInterval,
    reporter: Reporter?
  ) throws -> String {
    // launchctl state can only be read from a fully booted device, so a shut-down
    // source is booted for a moment; both states converge here before the copy.
    report(reporter, "Booting \(source.udid) to capture its service profile...")
    do { try bootAndWait(set: source.set, udid: source.udid) } catch {
      throw SimSlimError(
        "boot source to capture its service profile: \(error.localizedDescription)")
    }
    let disabled: Set<String>
    do { disabled = try readDisabled(set: source.set, udid: source.udid) } catch {
      throw SimSlimError("capture source service profile: \(error.localizedDescription)")
    }
    let desired = desiredCloneDisabled(disabled)
    do { try shutdown(set: source.set, udid: source.udid) } catch {
      throw SimSlimError("shutdown source before cloning: \(error.localizedDescription)")
    }
    do { try waitShutdown(set: source.set, udid: source.udid) } catch {
      throw SimSlimError(
        "wait for source shutdown before cloning: \(error.localizedDescription)")
    }

    // What exists now, so a clone UDID that names an existing simulator (the
    // source included) is recognised before anything can be deleted by it.
    let existing = Set(try listDevices().map { $0.udid.uppercased() })
    report(reporter, "Cloning \(source.udid)...")
    let output = try xcrunChecked(simctlArgs(set: source.set, ["clone", source.udid, name]))
    let created = try Simctl.parseClonedUDID(output.stdoutText)
    if created.uppercased() == source.udid.uppercased() || existing.contains(created.uppercased()) {
      throw SimSlimError(
        "simctl clone returned the UDID of an existing simulator (\(created)); nothing was deleted")
    }

    do {
      let paths = try cloneFilesystem(
        source: source, sourceData: sourceData, cloneUDID: created, home: home)
      report(reporter, "Rebasing the clone away from its source...")
      try sanitizeClonedDevice(paths)

      // Enforce the captured state instead of trusting a copied launchd database.
      // `ensure` also clears a required-to-run label that was disabled in the
      // source, and verifies persistence across a reboot when it changes.
      do {
        try ensure(set: source.set, udid: created, desired: desired, reporter: reporter)
      } catch {
        throw SimSlimError("restore cloned service profile: \(error.localizedDescription)")
      }
      try verifyRunningCloneDoesNotOpenSource(paths)
      do { try shutdown(set: source.set, udid: created) } catch {
        throw SimSlimError("shutdown prepared clone: \(error.localizedDescription)")
      }
      do { try waitShutdown(set: source.set, udid: created) } catch {
        throw SimSlimError("wait for prepared clone shutdown: \(error.localizedDescription)")
      }
      try verifyCloneIndependence(paths)
    } catch {
      let cleanup = detached(restoreTimeout).deleteUnsafeClone(set: source.set, udid: created)
      if let cleanup {
        throw SimSlimError(
          "prepare cloned simulator \(created): \(error.localizedDescription); additionally could not delete the unsafe clone: \(cleanup)"
        )
      }
      throw SimSlimError(
        "prepare cloned simulator \(created): \(error.localizedDescription); deleted the unsafe clone"
      )
    }
    return created
  }

  /// Parses `simctl clone` output: exactly one 36-character UDID.
  static func parseClonedUDID(_ output: String) throws -> String {
    let udid = goTrimSpace(output)
    let invalid = SimSlimError("simctl clone returned an invalid UDID \(goQuote(udid))")
    let scalars = Array(udid.unicodeScalars)
    guard scalars.count == 36 else { throw invalid }
    for (index, scalar) in scalars.enumerated() {
      if [8, 13, 18, 23].contains(index) {
        guard scalar == "-" else { throw invalid }
      } else {
        guard
          ("0"..."9").contains(scalar) || ("a"..."f").contains(scalar)
            || ("A"..."F").contains(scalar)
        else { throw invalid }
      }
    }
    return udid
  }

  // MARK: - repair-clone

  /// Removes direct file-system links and open paths into `sourceUDID` from a
  /// clone made by an older simslim. CoreSimulator keeps no clone lineage, so the
  /// caller names the real source. The clone keeps its apps, data, settings and
  /// service profile, and its boot state; a failed repair leaves it shut down.
  public func repairClonedDevice(
    sourceUDID: String, cloneUDID: String, home: String, restoreTimeout: TimeInterval,
    reporter: Reporter? = nil
  ) throws {
    if sourceUDID == cloneUDID {
      throw SimSlimError("clone source and destination UDIDs must be distinct")
    }
    let (source, sourceData) = try simulatorDataDirectory(udid: sourceUDID)
    let (clone, _) = try simulatorDataDirectory(udid: cloneUDID)
    if source.set != clone.set {
      throw SimSlimError("source and clone must belong to the same simulator set")
    }
    if source.platformName != clone.platformName || source.osVersion != clone.osVersion {
      throw SimSlimError(
        "source and clone runtimes differ (\(source.runtimeName) and \(clone.runtimeName))")
    }
    for device in [source, clone] where device.state != "Booted" && device.state != "Shutdown" {
      throw SimSlimError(
        "simulator \(device.udid) must be booted or shutdown before repair (it is \(device.state))"
      )
    }
    let paths = try cloneFilesystem(
      source: source, sourceData: sourceData, cloneUDID: cloneUDID, home: home)
    let sourceWasBooted = source.state == "Booted"
    let cloneWasBooted = clone.state == "Booted"

    var failure: Error?
    do {
      try repairBody(
        source: source, clone: clone, paths: paths, cloneWasBooted: cloneWasBooted,
        reporter: reporter)
    } catch {
      failure = error
    }

    // A failed repair leaves the clone shut down, then the source goes back.
    if failure != nil {
      do {
        try detached(restoreTimeout).restoreState(set: clone.set, udid: cloneUDID, booted: false)
      } catch {
        failure = SimSlimError(
          "\(failure!.localizedDescription); additionally could not leave the clone safely shutdown: \(error.localizedDescription)"
        )
      }
    }
    do {
      try detached(restoreTimeout).restoreState(
        set: source.set, udid: sourceUDID, booted: sourceWasBooted)
    } catch {
      let restore = error.localizedDescription
      if let failure {
        throw SimSlimError(
          "\(failure.localizedDescription); additionally could not restore the source boot state: \(restore)"
        )
      }
      throw SimSlimError("clone repaired, but could not restore the source boot state: \(restore)")
    }
    if let failure { throw failure }
  }

  private func repairBody(
    source: Device, clone: Device, paths: CloneFilesystem, cloneWasBooted: Bool,
    reporter: Reporter?
  ) throws {
    // Stop a running legacy clone first so it cannot keep writing through a
    // source-bound symlink while the source shuts down. Both devices are offline
    // before any copied state is rebuilt.
    report(reporter, "Shutting both simulators down...")
    do { try restoreState(set: clone.set, udid: clone.udid, booted: false) } catch {
      throw SimSlimError("shutdown clone before repair: \(error.localizedDescription)")
    }
    do { try restoreState(set: source.set, udid: source.udid, booted: false) } catch {
      throw SimSlimError("shutdown source before clone repair: \(error.localizedDescription)")
    }

    // Sanitizing does not touch launchd's override database. It runs before the
    // first boot so a shut-down legacy clone never starts with a Library symlink
    // that still resolves into the source.
    report(reporter, "Rebasing the clone away from its source...")
    try sanitizeClonedDevice(paths)
    do { try bootAndWait(set: clone.set, udid: clone.udid) } catch {
      throw SimSlimError("boot clone to capture its service profile: \(error.localizedDescription)")
    }
    let disabled: Set<String>
    do { disabled = try readDisabled(set: clone.set, udid: clone.udid) } catch {
      throw SimSlimError("capture cloned service profile: \(error.localizedDescription)")
    }
    do {
      try ensure(
        set: clone.set, udid: clone.udid, desired: desiredCloneDisabled(disabled),
        reporter: reporter)
    } catch {
      throw SimSlimError("restore repaired clone service profile: \(error.localizedDescription)")
    }
    try verifyRunningCloneDoesNotOpenSource(paths)
    if !cloneWasBooted {
      do { try restoreState(set: clone.set, udid: clone.udid, booted: false) } catch {
        throw SimSlimError("restore clone shutdown state: \(error.localizedDescription)")
      }
    }
  }

  // MARK: - shared steps

  /// Brings a device to Booted or Shutdown, doing nothing if it already is.
  func restoreState(set: String, udid: String, booted: Bool) throws {
    let device = try findDevice(udid: udid, set: set)
    if booted {
      if device.state == "Booted" { return }
      try bootAndWait(set: set, udid: udid)
      return
    }
    if device.state == "Shutdown" { return }
    try shutdown(set: set, udid: udid)
    try waitShutdown(set: set, udid: udid)
  }

  /// Stops and deletes a clone that could not be made independent. Returns what
  /// went wrong, or nil.
  private func deleteUnsafeClone(set: String, udid: String) -> String? {
    var stopError: String?
    do {
      try shutdown(set: set, udid: udid)
      try waitShutdown(set: set, udid: udid)
    } catch {
      stopError = error.localizedDescription
    }
    do {
      _ = try xcrunChecked(simctlArgs(set: set, ["delete", udid]))
      return nil
    } catch {
      if let stopError {
        return "stop clone: \(stopError); delete clone: \(error.localizedDescription)"
      }
      return error.localizedDescription
    }
  }

  private func cloneFilesystem(
    source: Device, sourceData: String, cloneUDID: String, home: String
  ) throws -> CloneFilesystem {
    let (clone, cloneData) = try simulatorDataDirectory(udid: cloneUDID)
    if clone.set != source.set {
      throw SimSlimError(
        "CoreSimulator placed clone \(cloneUDID) in \(clone.set) instead of source set \(source.set)"
      )
    }
    let logs = ["Library", "Logs", "CoreSimulator"].reduce(home) { join($0, $1) }
    func parent(_ path: String) -> String {
      (cleanPath(path) as NSString).deletingLastPathComponent
    }
    return CloneFilesystem(
      sourceUDID: source.udid, cloneUDID: cloneUDID,
      sourceDeviceDirectory: parent(sourceData), cloneDeviceDirectory: parent(cloneData),
      sourceDataDirectory: sourceData, cloneDataDirectory: cloneData,
      sourceLogDirectory: join(logs, source.udid), cloneLogDirectory: join(logs, cloneUDID))
  }

  // MARK: - running audit

  private static let auditAttempts = 3
  private static let auditDelay: TimeInterval = 0.1

  /// Makes the file-system checks observable at run time too: it catches a copied
  /// registry or preference holding an absolute path that no symlink represents.
  func verifyRunningCloneDoesNotOpenSource(_ paths: CloneFilesystem) throws {
    var last = ""
    for attempt in 0..<Simctl.auditAttempts {
      let outcome = auditRunningCloneOpenFilesOnce(paths)
      if outcome.complete {
        if let message = outcome.error { throw SimSlimError(message) }
        return
      }
      last = outcome.error ?? ""
      if attempt + 1 == Simctl.auditAttempts { break }
      pause(Simctl.auditDelay)
      if deadlineExpired {
        throw SimSlimError("audit cloned simulator open files: \(contextError)")
      }
    }
    throw SimSlimError(last)
  }

  /// `complete` is false only when process churn prevented a meaningful snapshot;
  /// the caller retries those.
  private func auditRunningCloneOpenFilesOnce(_ paths: CloneFilesystem) -> (
    complete: Bool, error: String?
  ) {
    let ps: CommandResult
    do { ps = try exec(.ps, ["eww", "-axo", "pid=,command="]) } catch {
      return (true, "enumerate cloned simulator processes: \(error.localizedDescription)")
    }
    guard ps.succeeded else {
      return (true, "enumerate cloned simulator processes: exit status \(ps.status)")
    }
    let pids = Simctl.simulatorProcessIDs(fromPS: ps.stdoutText, udid: paths.cloneUDID)
    if pids.isEmpty {
      return (
        false, "could not identify any running processes for cloned simulator \(paths.cloneUDID)"
      )
    }
    let result: CommandResult
    do {
      result = try exec(
        .lsof, ["-n", "-P", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")])
    } catch {
      return (false, "audit cloned simulator open files: \(error.localizedDescription)")
    }
    let failure =
      result.succeeded ? nil : (result.timedOut ? "signal: killed" : "exit status \(result.status)")
    return Simctl.evaluateCloneLsofAudit(
      result.stdoutText + result.stderrText, commandFailure: failure, paths: paths)
  }

  static func evaluateCloneLsofAudit(
    _ output: String, commandFailure: String?, paths: CloneFilesystem
  ) -> (complete: Bool, error: String?) {
    let parsed = parseCloneLsofOutput(output, paths: paths)
    if let first = parsed.references.first {
      return (
        true, "clone process \(first.pid) still has a source simulator path open: \(first.path)"
      )
    }
    // lsof exits 1 when any PID from the snapshot already exited, yet still
    // emits complete records for every process that is alive.
    if parsed.hasRecords { return (true, nil) }
    if let commandFailure {
      let message = goTrimSpace(output)
      if message.isEmpty { return (false, "audit cloned simulator open files: \(commandFailure)") }
      return (false, "audit cloned simulator open files: \(commandFailure): \(message)")
    }
    return (false, "audit cloned simulator open files returned no process or path records")
  }

  /// PIDs whose environment (from `ps eww`) names this simulator, ascending.
  static func simulatorProcessIDs(fromPS output: String, udid: String) -> [Int] {
    let marker = "SIMULATOR_UDID=" + udid
    var seen = Set<Int>()
    for bytes in output.utf8.split(separator: 10, omittingEmptySubsequences: false) {
      let line = String(decoding: bytes, as: UTF8.self)
      guard line.contains(marker) else { continue }
      guard let field = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
        let pid = Int(field), pid > 0
      else { continue }
      seen.insert(pid)
    }
    return seen.sorted()
  }

  struct SourceReference: Equatable {
    var pid: Int
    var path: String
  }

  static func parseCloneLsofOutput(_ output: String, paths: CloneFilesystem) -> (
    references: [SourceReference], hasRecords: Bool
  ) {
    var references: [SourceReference] = []
    var hasRecords = false
    var currentPID = 0
    for bytes in output.utf8.split(separator: 10, omittingEmptySubsequences: false) {
      guard bytes.count >= 2, let tag = bytes.first else { continue }
      let rest = String(decoding: bytes.dropFirst(), as: UTF8.self)
      switch tag {
      case UInt8(ascii: "p"):
        if let pid = Int(rest), pid > 0 { currentPID = pid } else { currentPID = 0 }
      case UInt8(ascii: "n"):
        guard currentPID > 0 else { continue }
        hasRecords = true
        let inDevice =
          rebasePath(
            rest, sourceRoot: paths.sourceDeviceDirectory, cloneRoot: paths.cloneDeviceDirectory)
          != nil
        let inLogs =
          rebasePath(
            rest, sourceRoot: paths.sourceLogDirectory, cloneRoot: paths.cloneLogDirectory) != nil
        // The roots come from simctl and lsof prints real paths, so a symlinked
        // CoreSimulator directory defeats the prefix test; the UDID component
        // catches that.
        let named = pathContainsComponent(rest, paths.sourceUDID)
        if inDevice || inLogs || named {
          references.append(SourceReference(pid: currentPID, path: rest))
        }
      default: break
      }
    }
    return (references, hasRecords)
  }
}
