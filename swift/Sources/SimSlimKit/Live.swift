import Foundation

// `enable` / `disable`: change categories or daemons on a booted simulator now,
// without a reboot, keeping no state of their own. The profile file given with
// --save is the only thing that persists.

extension Simctl {
  /// Re-enables categories (IDs from `simslim profiles`) and individual managed
  /// daemons on a booted simulator: each disable override is lifted and each job
  /// loaded into the running boot session. With `save`, the change is also
  /// written to that profile file once the live change succeeded; a simulator
  /// that is not booted only gets the file, and without `save` it is an error.
  public func enableServices(
    udid: String, ids: [String], save: String = "", reporter: Reporter? = nil
  ) throws -> ServicesOutput {
    let (categories, labels) = try resolveServiceIDs(ids)
    if categories.count + labels.count == 0 {
      throw SimSlimError(
        "name at least one category ID or managed daemon to enable (see `simslim profiles`)")
    }
    try checkSave(save, categories: categories, labels: labels, enable: true)
    let device = try serviceTarget(udid: udid, save: save)
    var out = ServicesOutput(action: "enable", udid: device.udid, live: device.state == "Booted")
    if out.live {
      out.labels = Catalog.covered(categories: categories, labels: labels).sorted()
      report(reporter, "Starting \(out.labels.count) background services without a reboot...")
      do {
        out.notStarted = try startServices(device: device, labels: out.labels, reporter: reporter)
      } catch {
        throw unsaved(error, save: save)
      }
    }
    try saveServices(&out, save: save, categories: categories, labels: labels, enable: true)
    return out
  }

  /// The inverse: stops categories and daemons at once, each one booted out of
  /// the running boot session with its disable override set. A daemon named on
  /// its own is always stopped, unless the platform needs it. A daemon a named
  /// category covers is also kept while another category that lists it is fully
  /// enabled right now. Both are reported in `stillEnabled`.
  public func disableServices(
    udid: String, ids: [String], save: String = "", reporter: Reporter? = nil
  ) throws -> ServicesOutput {
    let (categories, labels) = try resolveServiceIDs(ids)
    if categories.count + labels.count == 0 {
      throw SimSlimError(
        "name at least one category ID or managed daemon to disable (see `simslim profiles`)")
    }
    for label in labels where !Catalog.slimmableSet.contains(label) {
      throw SimSlimError(
        "\(label) is never disabled: simslim keeps it running for compatibility (see `simslim profiles`)"
      )
    }
    try checkSave(save, categories: categories, labels: labels, enable: false)
    let device = try serviceTarget(udid: udid, save: save)
    var out = ServicesOutput(action: "disable", udid: device.udid, live: device.state == "Booted")
    if out.live {
      do {
        try stopNamed(
          device: device, out: &out, categories: categories, labels: labels, reporter: reporter)
      } catch {
        throw unsaved(error, save: save)
      }
    }
    try saveServices(&out, save: save, categories: categories, labels: labels, enable: false)
    return out
  }

  /// Stops what `disableServices` was told to on a booted simulator, filling
  /// `out.labels` with what it stops and `out.stillEnabled` with what it keeps.
  private func stopNamed(
    device: Device, out: inout ServicesOutput, categories: [String], labels: [String],
    reporter: Reporter?
  ) throws {
    let disabled = try readDisabled(set: device.set, udid: device.udid)
    let covered = Catalog.covered(categories: categories, labels: labels)
    let allowed = desiredForDevice(device, covered)
    let kept = enabledNeighbours(disabling: categories, named: labels, disabled: disabled)
    for label in covered.sorted() {
      if allowed.contains(label) && Catalog.slimmableSet.contains(label) && !kept.contains(label) {
        out.labels.append(label)
      } else {
        out.stillEnabled.append(label)
      }
    }
    if out.labels.isEmpty { return }
    report(reporter, "Stopping \(out.labels.count) background services without a reboot...")
    try stopServices(device: device, labels: out.labels, reporter: reporter)
  }

  /// The labels the disabling categories cover that another category, one not
  /// being disabled and with every label enabled right now, also lists. Only the
  /// live state says which features are on, so that decides: stopping the store
  /// keeps the AMS daemons iCloud shares while iCloud is fully running. A label
  /// named on its own is never kept.
  func enabledNeighbours(disabling: [String], named: [String], disabled: Set<String>)
    -> Set<String>
  {
    var covered = Catalog.covered(categories: disabling, labels: [])
    covered.subtract(named)
    var kept = Set<String>()
    for category in Catalog.categories where !disabling.contains(category.id) {
      let enabled = category.labels.allSatisfy { !disabled.contains($0) }
      let shares = category.labels.contains { covered.contains($0) }
      if !enabled || !shares { continue }
      for label in category.labels where covered.contains(label) { kept.insert(label) }
    }
    return kept
  }

  // MARK: - --save

  /// Validates the profile file --save names before anything changes, so a bad
  /// file fails the command up front.
  private func checkSave(_ save: String, categories: [String], labels: [String], enable: Bool)
    throws
  {
    if save.isEmpty { return }
    _ = try updatedProfile(path: save, categories: categories, labels: labels, enable: enable)
  }

  private func saveServices(
    _ out: inout ServicesOutput, save: String, categories: [String], labels: [String],
    enable: Bool
  ) throws {
    if save.isEmpty { return }
    do {
      try SimSlimKit.saveServices(
        path: save, categories: categories, labels: labels, enable: enable)
    } catch {
      if out.live {
        throw SimSlimError(
          "the simulator was changed, but profile \(save) was not: \(error.localizedDescription)")
      }
      throw error
    }
    out.saved = save
  }

  /// Notes on a failed live change that --save left the profile alone.
  private func unsaved(_ error: Error, save: String) -> Error {
    if save.isEmpty { return error }
    return SimSlimError("\(error.localizedDescription) (profile \(save) not changed)")
  }

  /// Resolves the exact simulator `enable` and `disable` act on, so a simctl
  /// alias such as "all" can never fan out across devices. Only a booted
  /// simulator can change live; with a profile to save, any simulator is fine.
  private func serviceTarget(udid: String, save: String) throws -> Device {
    let device = try findDevice(udid: udid)
    if device.state != "Booted" && save.isEmpty {
      throw SimSlimError(
        "simulator \(device.udid) is not booted (it is \(device.state)): enable and disable change a running simulator only; pass --save <profile.json> to record the change, then apply it with `simslim on \(device.udid) --profile <profile.json>`"
      )
    }
    return device
  }

  /// Sorts the IDs `enable` and `disable` accept into category IDs and
  /// individual managed labels, rejecting anything else.
  func resolveServiceIDs(_ ids: [String]) throws -> (categories: [String], labels: [String]) {
    var categories: [String] = []
    var labels: [String] = []
    var seen = Set<String>()
    for id in ids {
      if seen.contains(id) { continue }
      if Catalog.category(id: id) != nil {
        categories.append(id)
      } else if Catalog.managedSet.contains(id) {
        labels.append(id)
      } else {
        throw SimSlimError(
          "unknown category or managed daemon \"\(id)\" (see `simslim profiles`)")
      }
      seen.insert(id)
    }
    return (categories.sorted(), labels.sorted())
  }

  // MARK: - Live transitions

  /// Lifts the disable override of each label and loads its job into the running
  /// boot session. One `launchctl load -w` per chunk handles every label whose
  /// job plist is found; what is still disabled afterwards gets a per-label
  /// `enable`, and what is still not loaded a per-label bootstrap. A label with
  /// no plist (an XPC service, for example) only needs its override lifted.
  /// Labels launchd re-enabled but would not load in this boot session are
  /// returned; they start at the next boot. A label left disabled is an error.
  func startServices(device: Device, labels: [String], reporter: Reporter?) throws -> [String] {
    let set = device.set
    let udid = device.udid
    var (disabled, loaded) = try serviceState(set: set, udid: udid)
    let candidates = labels.filter { disabled.contains($0) || !loaded.contains($0) }
    var plists: [String: String] = [:]
    var haveRoot = false
    if !device.runtimeID.isEmpty && !candidates.isEmpty,
      let root = try? runtimeRoot(runtimeID: device.runtimeID)
    {
      plists = launchdJobPlists(
        root: root, labels: candidates, plistLabel: { try self.readPlistLabel(path: $0) })
      haveRoot = true
    }
    // Without the RuntimeRoot nothing tells a missing plist from an unknown one,
    // so every unloaded label counts as one launchd should load.
    let loadable: (String) -> Bool = { plists[$0] != nil || !haveRoot }
    let pending = candidates.filter { disabled.contains($0) || loadable($0) }
    if pending.isEmpty {
      report(reporter, "  all \(labels.count) services were already running")
      return []
    }
    let paths = pending.compactMap { plists[$0] }
    if !paths.isEmpty {
      batchJobs(set: set, udid: udid, verb: "load", paths: paths)
      (disabled, loaded) = try serviceState(set: set, udid: udid)
      let left = stillToStart(pending, disabled: disabled, loaded: loaded, loadable: loadable)
      report(
        reporter, "  \(pending.count - left.count)/\(pending.count) services started in one batch")
    }
    var toEnable: [String] = []
    var unloaded: [String: String] = [:]
    for label in pending {
      if disabled.contains(label) { toEnable.append(label) }
      if let plist = plists[label], !loaded.contains(label) { unloaded[label] = plist }
    }
    if !toEnable.isEmpty {
      try applyDelta(
        set: set, udid: udid, toDisable: [], toEnable: toEnable, disableAction: .overrideOnly,
        reporter: reporter)
    }
    if !unloaded.isEmpty { bootstrapJobs(set: set, udid: udid, plists: unloaded) }
    if toEnable.count + unloaded.count > 0 {
      (disabled, loaded) = try serviceState(set: set, udid: udid)
    }
    var still: [String] = []
    var notStarted: [String] = []
    for label in pending {
      if disabled.contains(label) {
        still.append(label)
      } else if !loaded.contains(label) && loadable(label) {
        notStarted.append(label)
      }
    }
    if !still.isEmpty {
      throw SimSlimError(
        "\(still.count) of \(pending.count) services are still disabled: \(still.joined(separator: ", "))"
      )
    }
    return notStarted
  }

  /// The labels that are still disabled, or still not loaded although launchd
  /// could load them.
  func stillToStart(
    _ labels: [String], disabled: Set<String>, loaded: Set<String>,
    loadable: (String) -> Bool
  ) -> [String] {
    labels.filter { disabled.contains($0) || (!loaded.contains($0) && loadable($0)) }
  }

  /// One `launchctl bootstrap` per job, for the few the batch load left behind.
  /// The exit status is not trusted (an already-loaded job exits 37); the
  /// caller reads the state back.
  func bootstrapJobs(set: String, udid: String, plists: [String: String]) {
    for label in plists.keys.sorted() {
      if deadlineExpired { return }
      _ = try? exec(
        .xcrun,
        simctlArgs(set: set, ["spawn", udid, "launchctl", "bootstrap", "system", plists[label]!]),
        timeout: spawnTimeout)
    }
  }

  /// The disable overrides and the loaded jobs, read together.
  func serviceState(set: String, udid: String) throws -> (
    disabled: Set<String>, loaded: Set<String>
  ) {
    (
      try readDisabled(set: set, udid: udid),
      try loadedLabels(set: set, udid: udid)
    )
  }

  /// Disables each label and boots its job out of the running boot session: one
  /// `launchctl unload -w` per chunk first, then a per-label disable and bootout
  /// for whatever the batch missed. Every override is read back.
  func stopServices(device: Device, labels: [String], reporter: Reporter?) throws {
    let remaining = unloadInBatch(
      set: device.set, udid: device.udid, runtimeID: device.runtimeID, labels: labels,
      reporter: reporter)
    try applyDelta(
      set: device.set, udid: device.udid, toDisable: remaining, toEnable: [],
      disableAction: .liveStop, reporter: reporter)
    let after = try readDisabled(set: device.set, udid: device.udid)
    let missing = labels.filter { !after.contains($0) }.count
    if missing > 0 {
      throw SimSlimError("\(missing) of \(labels.count) disable overrides did not take")
    }
  }
}
