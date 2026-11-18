import Foundation

/// How often `watch` rescans the device sets.
public let defaultWatchInterval: TimeInterval = 3

/// How long `watch` waits for a new device directory's device.plist, which
/// `simctl create` writes just after the directory.
let newDevicePlistWait: TimeInterval = 2

/// The WatchEvent kinds. A wrapper that boots a device and then changes its
/// services waits for `slimmed` (or `failed`): after it, the watcher does not
/// touch that device again until the device shuts down.
public enum WatchEventKind {
  public static let slimming = "slimming"  // an after-boot pass started
  public static let slimmed = "slimmed"  // the pass for the current boot finished
  public static let failed = "failed"  // the pass failed; the next scan retries it
  public static let stopped = "stopped"  // the device shut down, so its pass was cancelled
  public static let slimmedBeforeBoot = "slimmed_before_boot"  // disables written to a store
}

/// The stable, machine-readable form of a watcher log line.
public struct WatchEvent: Equatable, Sendable {
  public var event: String
  public var udid: String
  public var set: String
  public var services: Int  // disables written, for slimmed_before_boot
  public var error: String  // for failed

  public init(event: String, udid: String, set: String, services: Int = 0, error: String = "") {
    self.event = event
    self.udid = udid
    self.set = set
    self.services = services
    self.error = error
  }

  /// One compact JSON object, keys in the Go struct's order, empty `services`
  /// and `error` omitted.
  public var jsonLine: String {
    var fields = [
      "\"event\":\(WatchEvent.quote(event))", "\"udid\":\(WatchEvent.quote(udid))",
      "\"set\":\(WatchEvent.quote(set))",
    ]
    if services != 0 { fields.append("\"services\":\(services)") }
    if !error.isEmpty { fields.append("\"error\":\(WatchEvent.quote(error))") }
    return "{" + fields.joined(separator: ",") + "}"
  }

  private static func quote(_ text: String) -> String {
    let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
    return String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
  }
}

/// The device sets' on-disk directories, mapped to each set's name: the default
/// set, Xcode's parallel-testing set, and any `--set` path.
func deviceSetDirs(_ simctl: Simctl, home: String) -> [String: String] {
  var dirs: [String: String] = [:]
  let developer = ((home as NSString).appendingPathComponent("Library") as NSString)
    .appendingPathComponent("Developer")
  for set in simctl.knownSets {
    switch set.token {
    case "":
      dirs[
        ((developer as NSString).appendingPathComponent("CoreSimulator") as NSString)
          .appendingPathComponent("Devices")] = set.name
    case "testing": dirs[(developer as NSString).appendingPathComponent("XCTestDevices")] = set.name
    default: dirs[set.token] = set.name
    }
  }
  return dirs
}

/// Reads the device CoreSimulator describes in a device directory's
/// device.plist: its UDID, runtime and state (1 is Shutdown).
func readDevicePlist(_ dir: DeviceDir) throws -> Device {
  let file = (dir.path as NSString).appendingPathComponent("device.plist")
  let data = try Data(contentsOf: URL(fileURLWithPath: file))
  let object: Any
  do {
    object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
  } catch {
    throw SimSlimError("parse device.plist: \(error.localizedDescription)")
  }
  let dict = object as? [String: Any] ?? [:]
  // Strings and integers both read as text, as in Go.
  func text(_ key: String) -> String {
    if let value = dict[key] as? String { return value }
    if let value = dict[key] as? NSNumber { return value.stringValue }
    return ""
  }
  let runtime = text("runtime")
  guard let parsed = Simctl.parseRuntime(runtime), !text("UDID").isEmpty else {
    throw SimSlimError("device.plist names no UDID or supported runtime")
  }
  return Device(
    udid: text("UDID"), state: text("state") == "1" ? "Shutdown" : "Booted",
    platform: parsed.platform, osVersion: parsed.version, set: dir.set,
    dataPath: (dir.path as NSString).appendingPathComponent("data"), runtimeID: runtime)
}

/// Writes the profile's missing disable overrides into a shut-down device's
/// launchd store and reports how many it added. Like the no-reboot slim `watch`
/// applies after boot, it only ever adds disables: a service someone disabled
/// beyond the profile stays disabled, and nothing is re-enabled. A device that is
/// not shut down, or whose runtime does not persist overrides, is left alone; the
/// after-boot slim covers it.
func preslimDevice(_ device: Device, profile: Profile, storeRoot: String) throws -> Int {
  if device.state != "Shutdown" || !device.supportsPersistentOverrides { return 0 }
  let store = DisabledStore(root: storeRoot)
  let current = try store.readDisabled(udid: device.udid)
  let toDisable = delta(
    current: current, desired: profile.desired(for: device), managed: Catalog.managedSet
  ).toDisable
  if toDisable.isEmpty { return 0 }
  try store.write(udid: device.udid, toDisable: toDisable, toEnable: [])
  return toDisable.count
}

/// Slims every simulator so that none starts the profile's daemons, then leaves
/// it alone until it boots again. A shut-down simulator on a runtime that
/// persists overrides is slimmed before it boots: the profile's disable
/// overrides are written into its launchd store, so its next boot, its very
/// first included, starts none of those daemons. New devices are caught by a
/// kqueue watch on the device-set directories, ahead of a tool that creates and
/// boots at once. Every simulator is still slimmed no-reboot as it boots: that
/// reads the device back, and it is the only hook for a device that booted before
/// its store was seeded, on an older runtime, or as an xcodebuild
/// parallel-testing clone (cloned stock, since overrides do not survive
/// `simctl clone`, and booted at once).
public final class Watcher: @unchecked Sendable {
  /// One boot's after-boot slim. Cancelling it stops it once that boot ends, so
  /// it cannot keep retrying into the device's next boot.
  final class Pass: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return flag
    }
    func cancel() {
      lock.lock()
      flag = true
      lock.unlock()
    }
  }

  public typealias Slimmer = @Sendable (Simctl, String, String, Profile, Reporter?) throws -> Bool
  public typealias Preslimmer = @Sendable (Device, Profile) throws -> Int

  let profile: Profile
  var simctl: Simctl
  let report: Reporter?
  let events: (@Sendable (WatchEvent) -> Void)?
  let home: String
  /// The per-device slim; a field so tests can substitute a fake.
  var slim: Slimmer
  /// Seeds a shut-down device before it boots; a field so tests can substitute
  /// a fake.
  var preslim: Preslimmer?

  private let lock = NSLock()
  private var passes: [String: Pass] = [:]
  private var seeded = Set<String>()
  private let group = DispatchGroup()
  private var stopRequested: @Sendable () -> Bool = { false }
  private var wakeFlag = false
  private let wakeup = DispatchSemaphore(value: 0)

  public init(
    simctl: Simctl, profile: Profile, home: String = NSHomeDirectory(),
    report: Reporter? = nil, events: (@Sendable (WatchEvent) -> Void)? = nil
  ) {
    self.simctl = simctl
    self.profile = profile
    self.home = home
    self.report = report
    self.events = events
    self.slim = { ctl, set, udid, profile, reporter in
      try ctl.enableSlimNoReboot(set: set, udid: udid, profile: profile, reporter: reporter)
    }
    let root = simctl.storeRoot
    self.preslim = { device, profile in
      try preslimDevice(device, profile: profile, storeRoot: root)
    }
  }

  /// Watches until `stop` returns true, scanning the default, testing and any
  /// `--set` device sets every `interval`. Each booted device is slimmed in its
  /// own thread so one slow reconfigure does not delay catching the next clone,
  /// and `run` returns once those are done.
  public func run(
    interval: TimeInterval = defaultWatchInterval, stop: @escaping @Sendable () -> Bool
  ) {
    let interval = interval > 0 ? interval : defaultWatchInterval
    stopRequested = stop
    simctl.cancelled = stop
    let dirs = deviceSetDirs(simctl, home: home)
    group.enter()
    Thread.detachNewThread { [self] in
      defer { group.leave() }
      watchDeviceDirs(setDirs: dirs, stop: stop) { dir in
        // seedNew waits for device.plist, so each new device gets its own
        // thread: a batch of parallel-testing clones seeds at once.
        group.enter()
        Thread.detachNewThread { [self] in
          defer { group.leave() }
          seedNew(dir)
          signalScan()
        }
      }
    }
    while !stop() {
      scan()
      var waited = 0.0
      while waited < interval && !stop() {
        if wakeup.wait(timeout: .now() + 0.2) == .success {
          lock.lock()
          wakeFlag = false
          lock.unlock()
          break
        }
        waited += 0.2
      }
    }
    // No slim may outlive the call; a stopped run aborts an in-flight slim at
    // its next command, which keeps the wait short.
    if group.wait(timeout: .now() + 20) == .timedOut {
      report?("watch: a slim was still running at exit")
    }
  }

  /// Asks the loop to scan now; coalesces while one is already due.
  private func signalScan() {
    lock.lock()
    let already = wakeFlag
    wakeFlag = true
    lock.unlock()
    if !already { wakeup.signal() }
  }

  /// Blocks until every slim and seed thread started so far has finished.
  func waitForWork() { group.wait() }

  private func emit(_ event: WatchEvent) { events?(event) }

  /// Slims a just-created device before its first boot, straight from its
  /// directory and without a `simctl list`, which on a loaded host would still be
  /// running when a script that boots right after creating has started launchd_sim.
  func seedNew(_ dir: DeviceDir) {
    let limit = Date().addingTimeInterval(newDevicePlistWait)
    var device: Device?
    while device == nil && Date() < limit {
      device = try? readDevicePlist(dir)
      if device == nil {
        if stopRequested() { return }
        Thread.sleep(forTimeInterval: 0.01)
      }
    }
    // Not a device, or not one simslim slims; the scan decides.
    guard let device else { return }
    seed(device)
  }

  func scan() {
    let devices: [Device]
    do {
      devices = try simctl.listDevices().sorted { $0.udid < $1.udid }
    } catch {
      report?("watch: list devices: \(error.localizedDescription)")
      return
    }
    prune(devices)
    for device in devices {
      if device.state != "Booted" {
        // On iOS below 18.5 the no-reboot slim dies with the boot session, so a
        // device that shut down comes back stock and needs slimming again.
        // Re-slimming an already-slim device is a cheap no-op.
        forget(device.udid)
        seed(device)
        continue
      }
      // A booted device may change its own store (and `simslim off` may clear
      // it), so check it again the next time it is shut down.
      lock.lock()
      seeded.remove(device.udid)
      lock.unlock()
      guard let pass = claim(device.udid) else { continue }
      group.enter()
      let stop = stopRequested
      var ctl = simctl
      ctl.cancelled = { pass.isCancelled || stop() }
      Thread.detachNewThread { [self] in
        defer { group.leave() }
        report?("watch: slimming \(device.udid) (set \(device.set))")
        emit(WatchEvent(event: WatchEventKind.slimming, udid: device.udid, set: device.set))
        var failure: Error?
        do {
          _ = try slim(ctl, device.set, device.udid, profile, prefixed(device.udid))
        } catch {
          failure = error
        }
        finish(device, pass, failure)
      }
    }
  }

  /// Slims a shut-down device ahead of its next boot, once per shutdown. A
  /// failure is retried on the next scan, and the after-boot slim still covers
  /// the device if it boots first.
  func seed(_ device: Device) {
    guard let preslim else { return }
    // A device caught Shutting Down or Booting is seeded once it reads Shutdown.
    if device.state != "Shutdown" { return }
    lock.lock()
    defer { lock.unlock() }  // serializes the store writes of seedNew and scan
    if seeded.contains(device.udid) { return }
    let count: Int
    do {
      count = try preslim(device, profile)
    } catch {
      report?("watch: \(device.udid): slim before boot: \(error.localizedDescription)")
      return
    }
    seeded.insert(device.udid)
    if count == 0 { return }
    // launchd_sim reads the store once, when it starts: a seed that lands after
    // the boot began only counts from the next boot.
    if !device.dataPath.isEmpty,
      let now = try? readDevicePlist(
        DeviceDir(path: (device.dataPath as NSString).deletingLastPathComponent, set: device.set)),
      now.state != "Shutdown"
    {
      report?(
        "watch: \(device.udid) booted before its slim (\(count) services) landed; slimming it as it boots"
      )
      return
    }
    report?(
      "watch: slimmed \(device.udid) before boot (\(count) services disabled, set \(device.set))")
    emit(
      WatchEvent(
        event: WatchEventKind.slimmedBeforeBoot, udid: device.udid, set: device.set,
        services: count))
  }

  /// Reports a pass's outcome. It holds the lock so a superseded pass, whose boot
  /// ended, can never announce slimmed after a newer boot's pass has started.
  func finish(_ device: Device, _ pass: Pass, _ failure: Error?) {
    lock.lock()
    defer { lock.unlock() }
    if passes[device.udid] !== pass {
      report?("watch: \(device.udid) shut down; stopped its slim")
      emit(WatchEvent(event: WatchEventKind.stopped, udid: device.udid, set: device.set))
    } else if let failure {
      // A transient launchctl failure would otherwise leave this clone stock for
      // the whole test run. The next scan retries it, and a torn-down clone drops
      // out of simctl list, so this does not loop.
      passes[device.udid] = nil
      report?("watch: \(device.udid): \(failure.localizedDescription)")
      emit(
        WatchEvent(
          event: WatchEventKind.failed, udid: device.udid, set: device.set,
          error: failure.localizedDescription))
    } else {
      report?("watch: slimmed \(device.udid)")
      emit(WatchEvent(event: WatchEventKind.slimmed, udid: device.udid, set: device.set))
    }
  }

  /// Starts a pass for a booted UDID, returning nil when one is already done or
  /// in flight for this boot.
  func claim(_ udid: String) -> Pass? {
    lock.lock()
    defer { lock.unlock() }
    if passes[udid] != nil { return nil }
    let pass = Pass()
    passes[udid] = pass
    return pass
  }

  /// Drops the UDIDs of deleted devices, such as finished parallel-testing
  /// clones, so `passes` and `seeded` do not grow by one entry per clone. A
  /// device created after the listing started is only seeded again, which is a
  /// no-op.
  func prune(_ devices: [Device]) {
    let listed = Set(devices.map(\.udid))
    lock.lock()
    defer { lock.unlock() }
    for (udid, pass) in passes where !listed.contains(udid) {
      pass.cancel()
      passes[udid] = nil
    }
    seeded = seeded.intersection(listed)
  }

  /// Ends a device's boot: its pass, if still running, is cancelled, and its next
  /// boot gets a pass of its own.
  func forget(_ udid: String) {
    lock.lock()
    if let pass = passes[udid] {
      pass.cancel()
      passes[udid] = nil
    }
    lock.unlock()
  }

  /// Tags a device's own progress lines with its UDID, so the interleaved output
  /// of concurrent slims stays attributable.
  private func prefixed(_ udid: String) -> Reporter? {
    guard let report else { return nil }
    return { report("watch: \(udid): \($0)") }
  }
}
