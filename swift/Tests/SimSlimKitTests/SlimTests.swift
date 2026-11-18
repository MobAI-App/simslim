import TestSupport
import XCTest

@testable import SimSlimKit

private final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var current = 0
  private(set) var peak = 0
  func enter() {
    lock.lock()
    current += 1
    peak = max(peak, current)
    lock.unlock()
  }
  func leave() {
    lock.lock()
    current -= 1
    lock.unlock()
  }
}

private final class Tally: @unchecked Sendable {
  private let lock = NSLock()
  private var counts: [String: Int] = [:]
  func bump(_ key: String) -> Int {
    lock.lock()
    defer { lock.unlock() }
    counts[key, default: 0] += 1
    return counts[key]!
  }
}

private final class Log: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func add(_ line: String) {
    lock.lock()
    lines.append(line)
    lock.unlock()
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}

final class SlimTests: XCTestCase {
  private let ios = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  private let old = "com.apple.CoreSimulator.SimRuntime.iOS-17-0"
  private let udid = "AAAAAAAA-0000-0000-0000-000000000001"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-slim-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private var profileLabels: Set<String> { Profile().desired() }

  private func host(
    state: String = "Shutdown", runtime: String? = nil, disabled: Set<String>? = nil
  ) -> FakeHost {
    let host = FakeHost(devices: [
      .init(udid: udid, name: "iPhone", runtime: runtime ?? ios, state: state)
    ])
    host.storeRoot = root + "/store"
    if state == "Booted" { host.disabled[udid] = disabled ?? [] }
    return host
  }

  private func simctl(_ host: FakeHost) -> Simctl {
    var simctl = Simctl(runner: host)
    simctl.retryDelays = [0, 0, 0, 0]
    simctl.sleep = { _ in }
    simctl.storeRoot = root + "/store"
    return simctl
  }

  private func storeFile() -> String {
    root + "/store/com.apple.CoreSimulator.SimDevice.\(udid)/disabled.plist"
  }

  private func verbs(_ host: FakeHost) -> [String] {
    host.calls.compactMap { call -> String? in
      guard call.executable == .xcrun else { return nil }
      var args = call.arguments
      if args.count > 2, args[1] == "--set" { args.removeSubrange(1...2) }
      if args.count > 2, args[1] == "spawn" { return "spawn:" + args[4...].joined(separator: " ") }
      return args.dropFirst().first
    }
  }

  private func transitions(_ host: FakeHost) -> [String] {
    verbs(host).filter {
      $0.hasPrefix("spawn:disable ") || $0.hasPrefix("spawn:enable ")
        || $0.hasPrefix("spawn:bootout ") || $0.hasPrefix("spawn:unload ")
    }
  }

  // MARK: - CRLF output

  func testParsersSplitCRLFLines() {
    XCTAssertEqual(
      Simctl.parseDisabled("\"a\" => disabled\r\n\"b\" => disabled\r\n\"c\" => enabled\r\n"),
      ["a", "b"])
    XCTAssertEqual(parseLaunchctlList("PID\tStatus\tLabel\r\n-\t0\tx\r\n-\t0\ty\r\n"), ["x", "y"])
  }

  // MARK: - DisabledStore

  func testStoreRoundTripAndMerge() throws {
    let store = DisabledStore(root: root + "/store")
    XCTAssertEqual(
      try store.readDisabled(udid: udid), [], "a device that never booted has no store")

    try store.write(udid: udid, toDisable: ["b.service", "a.service"], toEnable: [])
    XCTAssertEqual(try store.readDisabled(udid: udid), ["a.service", "b.service"])

    // Enabling records an explicit false and keeps everything else.
    try store.write(udid: udid, toDisable: ["c.service"], toEnable: ["a.service"])
    XCTAssertEqual(
      try store.readEntries(udid: udid),
      ["a.service": false, "b.service": true, "c.service": true])
    XCTAssertEqual(try store.readDisabled(udid: udid), ["b.service", "c.service"])
  }

  func testStoreKeepsTheRuntimesOwnEntries() throws {
    let dir = root + "/store/com.apple.CoreSimulator.SimDevice.\(udid)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let runtimeWritten = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>com.apple.runtime.enabled</key><false/>
      <key>com.apple.unmanaged.disabled</key><true/>
      </dict></plist>
      """
    try runtimeWritten.write(toFile: dir + "/disabled.plist", atomically: true, encoding: .utf8)

    let store = DisabledStore(root: root + "/store")
    try store.write(udid: udid, toDisable: ["com.apple.mine"], toEnable: [])
    XCTAssertEqual(
      try store.readEntries(udid: udid),
      [
        "com.apple.runtime.enabled": false, "com.apple.unmanaged.disabled": true,
        "com.apple.mine": true,
      ])
  }

  func testStoreWriteDoesNotDropNonBooleanEntries() throws {
    let dir = root + "/store/com.apple.CoreSimulator.SimDevice.\(udid)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let text = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>com.apple.other</key><integer>7</integer>
      <key>com.apple.runtime.enabled</key><false/>
      </dict></plist>
      """
    try text.write(toFile: dir + "/disabled.plist", atomically: true, encoding: .utf8)

    let store = DisabledStore(root: root + "/store")
    try store.write(udid: udid, toDisable: ["com.apple.mine"], toEnable: [])

    let data = try Data(contentsOf: URL(fileURLWithPath: dir + "/disabled.plist"))
    let dict = try XCTUnwrap(
      PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any])
    XCTAssertEqual(dict["com.apple.other"] as? Int, 7, "an entry simslim does not own must survive")
    XCTAssertEqual(dict["com.apple.mine"] as? Bool, true)
    XCTAssertEqual(dict["com.apple.runtime.enabled"] as? Bool, false)
  }

  func testStoreIgnoresNonBooleanValuesAndRejectsGarbage() throws {
    let text = """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>a</key><true/>
      <key>count</key><integer>1</integer>
      <key>name</key><string>true</string>
      </dict></plist>
      """
    XCTAssertEqual(try DisabledStore.parse(Data(text.utf8)), ["a": true])
    XCTAssertThrowsError(try DisabledStore.parse(Data("not a plist".utf8)))
  }

  func testStoreEncodesSortedAndEscaped() throws {
    let data = DisabledStore.encode(["z&<>": true, "a": false])
    let text = String(decoding: data, as: UTF8.self)
    XCTAssertLessThan(
      text.range(of: "<key>a</key>")!.lowerBound, text.range(of: "<key>z")!.lowerBound)
    XCTAssertTrue(text.contains("<key>z&amp;&lt;&gt;</key>"))
    XCTAssertEqual(try DisabledStore.parse(data), ["z&<>": true, "a": false])
    XCTAssertEqual(DisabledStore.encode(["z&<>": true, "a": false]), data, "stable output")
  }

  func testStoreWriteIsAtomicAndLeavesNoTemporaryFiles() throws {
    let store = DisabledStore(root: root + "/store")
    try store.write(udid: udid, toDisable: ["a"], toEnable: [])
    try store.write(udid: udid, toDisable: ["b"], toEnable: [])
    let dir = root + "/store/com.apple.CoreSimulator.SimDevice.\(udid)"
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir), ["disabled.plist"])
    let attrs = try FileManager.default.attributesOfItem(atPath: dir + "/disabled.plist")
    XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o644)
  }

  func testStoreWriteFailureIsAnError() throws {
    // A file where the device directory should be.
    try FileManager.default.createDirectory(
      atPath: root + "/store", withIntermediateDirectories: true)
    FileManager.default.createFile(
      atPath: root + "/store/com.apple.CoreSimulator.SimDevice.\(udid)", contents: Data())
    let store = DisabledStore(root: root + "/store")
    XCTAssertThrowsError(try store.write(udid: udid, toDisable: ["a"], toEnable: []))
  }

  // MARK: - ensure: refusals

  func testRefusesNonEmptyProfileOnRuntimeWithoutPersistence() throws {
    let host = host(state: "Booted", runtime: old)
    XCTAssertThrowsError(
      try simctl(host).ensure(set: "default", udid: udid, desired: profileLabels)
    ) { error in
      let text = "\(error)"
      XCTAssertTrue(text.contains("iOS 17.0 runtime cannot persist"), text)
      XCTAssertTrue(text.contains("iOS 18.5 or newer"), text)
    }
    // Nothing but the device lookup ran: no boot, shutdown or launchctl.
    XCTAssertEqual(verbs(host), ["list"])
  }

  // MARK: - ensure: offline route

  func testShutdownDeviceIsSlimmedByTheStoreWithOneBootAndNoSpawns() throws {
    let host = host()
    let lines = Log()
    let changed = try simctl(host).ensure(
      set: "default", udid: udid, desired: profileLabels, reporter: { lines.add($0) })
    XCTAssertTrue(changed)
    XCTAssertEqual(host.devices[0].state, "Booted")
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), profileLabels)
    XCTAssertTrue(transitions(host).isEmpty, "no per-label launchctl spawns: \(transitions(host))")
    XCTAssertEqual(verbs(host).filter { $0 == "boot" }.count, 1)
    XCTAssertFalse(verbs(host).contains("shutdown"))
    XCTAssertTrue(lines.all.contains { $0.hasPrefix("Reconfiguring \(profileLabels.count)") })
    XCTAssertEqual(try DisabledStore(root: root + "/store").readDisabled(udid: udid), profileLabels)
  }

  func testBootedDeviceWithADeltaShutsDownThenBootsOnce() throws {
    let host = host(state: "Booted")
    let changed = try simctl(host).ensure(set: "default", udid: udid, desired: profileLabels)
    XCTAssertTrue(changed)
    let v = verbs(host)
    let shutdownIndex = try XCTUnwrap(v.firstIndex(of: "shutdown"))
    let lastBoot = try XCTUnwrap(v.lastIndex(of: "boot"))
    XCTAssertLessThan(shutdownIndex, lastBoot)
    XCTAssertTrue(transitions(host).isEmpty)
    XCTAssertEqual(host.devices[0].state, "Booted")
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), profileLabels)
  }

  func testBootedDeviceAlreadyMatchingIsLeftAlone() throws {
    let host = host(state: "Booted", disabled: profileLabels)
    let changed = try simctl(host).ensure(set: "default", udid: udid, desired: profileLabels)
    XCTAssertFalse(changed)
    XCTAssertFalse(verbs(host).contains("shutdown"), "an already-slim device is not rebooted")
    XCTAssertTrue(transitions(host).isEmpty)
  }

  func testStockProfileRestoresEveryManagedLabelAndOnlyThose() throws {
    var all = Catalog.managedSet
    all.insert("com.apple.unmanaged.service")
    let host = host(state: "Booted", disabled: all)
    // The runtime's own record for the unmanaged label lives in the store.
    try DisabledStore(root: root + "/store").write(
      udid: udid, toDisable: Array(all), toEnable: [])
    let changed = try simctl(host).ensure(set: "default", udid: udid, desired: [])
    XCTAssertTrue(changed)
    XCTAssertEqual(host.disabled[udid], ["com.apple.unmanaged.service"])
  }

  func testManagedLabelsAreTheOnlyOnesEverWritten() throws {
    let host = host()
    try simctl(host).ensure(set: "default", udid: udid, desired: profileLabels)
    let written = try DisabledStore(root: root + "/store").readEntries(udid: udid)
    XCTAssertTrue(Set(written.keys).isSubset(of: Catalog.managedSet))
  }

  func testWatchOSKeepsHomedEnabledAndVisionOSKeepsMobileassetd() throws {
    let watch = FakeHost(devices: [
      .init(udid: udid, name: "Watch", runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-11-5")
    ])
    watch.storeRoot = root + "/store"
    try simctl(watch).ensure(set: "default", udid: udid, desired: profileLabels)
    XCTAssertFalse(watch.disabled[udid]!.contains("com.apple.homed"))

    let vision = FakeHost(devices: [
      .init(udid: udid, name: "Vision", runtime: "com.apple.CoreSimulator.SimRuntime.xrOS-2-5")
    ])
    vision.storeRoot = root + "/store2"
    var visionCtl = simctl(vision)
    visionCtl.storeRoot = root + "/store2"
    try visionCtl.ensure(set: "default", udid: udid, desired: profileLabels)
    XCTAssertFalse(vision.disabled[udid]!.contains("com.apple.mobileassetd"))
  }

  // MARK: - ensure: fallback to launchctl

  func testIgnoredStoreFallsBackToLaunchctlAndStillEndsSlim() throws {
    let host = host()
    host.honoursStore = false
    let lines = Log()
    let changed = try simctl(host).ensure(
      set: "default", udid: udid, desired: profileLabels, reporter: { lines.add($0) })
    XCTAssertTrue(changed)
    XCTAssertTrue(
      lines.all.contains { $0.hasPrefix("Could not apply the changes while the simulator was off") }
    )
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), profileLabels)
    XCTAssertEqual(
      transitions(host).filter { $0.hasPrefix("spawn:disable ") }.count, profileLabels.count)
    XCTAssertTrue(verbs(host).contains("shutdown"), "the fallback reboots to persist")
  }

  func testOverridesLostAtRebootIsAnError() throws {
    let host = host()
    host.honoursStore = false
    host.persistsOverrides = false  // the runtime lies about persistence
    XCTAssertThrowsError(
      try simctl(host).ensure(set: "default", udid: udid, desired: profileLabels)
    ) { error in
      XCTAssertTrue("\(error)".contains("did not survive the reboot"), "\(error)")
    }
  }

  func testUnreadableStoreFallsBack() throws {
    let host = host()
    let dir = root + "/store/com.apple.CoreSimulator.SimDevice.\(udid)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "garbage".write(toFile: dir + "/disabled.plist", atomically: true, encoding: .utf8)
    host.honoursStore = false
    let changed = try simctl(host).ensure(set: "default", udid: udid, desired: profileLabels)
    XCTAssertTrue(changed)
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), profileLabels)
  }

  // MARK: - applyDelta

  func testApplyDeltaRetriesAFailedLabelOnALaterPass() throws {
    let host = host(state: "Booted")
    let tally = Tally()
    host.failTransition = { verb, label in
      guard label == "com.apple.flaky" else { return nil }
      return tally.bump("\(verb) \(label)") == 1
        ? CommandResult(status: 124, stderr: Data("Domain is tearing down".utf8)) : nil
    }
    let lines = Log()
    try simctl(host).applyDelta(
      set: "default", udid: udid, toDisable: ["com.apple.flaky", "com.apple.fine"], toEnable: [],
      disableAction: .overrideOnly, reporter: { lines.add($0) })
    XCTAssertEqual(host.disabled[udid], ["com.apple.flaky", "com.apple.fine"])
    XCTAssertTrue(lines.all.contains { $0.contains("retrying 1 failed services (pass 2/3)") })
  }

  func testApplyDeltaGivesUpAfterThreePasses() throws {
    let host = host(state: "Booted")
    host.failTransition = { _, label in
      label == "com.apple.bad" ? CommandResult(status: 1, stderr: Data("nope".utf8)) : nil
    }
    XCTAssertThrowsError(
      try simctl(host).applyDelta(
        set: "default", udid: udid, toDisable: ["com.apple.bad", "com.apple.ok"], toEnable: [],
        disableAction: .overrideOnly, reporter: nil)
    ) { error in
      let text = "\(error)"
      XCTAssertTrue(text.contains("1/2 launchctl transitions failed after 3 passes"), text)
      XCTAssertTrue(text.contains("disable com.apple.bad: exit status 1: nope"), text)
    }
    XCTAssertEqual(host.disabled[udid], ["com.apple.ok"])
  }

  func testApplyDeltaEnablesAndDisables() throws {
    let host = host(state: "Booted", disabled: ["com.apple.on"])
    try simctl(host).applyDelta(
      set: "default", udid: udid, toDisable: ["com.apple.off"], toEnable: ["com.apple.on"],
      disableAction: .overrideOnly, reporter: nil)
    XCTAssertEqual(host.disabled[udid], ["com.apple.off"])
  }

  func testLiveStopBootsOutAndToleratesAnUnloadedService() throws {
    let host = host(state: "Booted")
    host.loaded[udid] = ["com.apple.running"]  // com.apple.gone is not loaded: bootout exits 3
    try simctl(host).applyDelta(
      set: "default", udid: udid, toDisable: ["com.apple.running", "com.apple.gone"], toEnable: [],
      disableAction: .liveStop, reporter: nil)
    XCTAssertEqual(host.disabled[udid], ["com.apple.running", "com.apple.gone"])
    XCTAssertEqual(host.loaded[udid], [])
    let outs = transitions(host).filter { $0.hasPrefix("spawn:bootout ") }
    XCTAssertEqual(outs.count, 2)
  }

  func testApplyDeltaUsesAtMostEightWorkers() throws {
    let host = host(state: "Booted")
    let counter = Counter()
    host.onCall = { _, args in
      guard args.contains("launchctl") else { return }
      counter.enter()
      Thread.sleep(forTimeInterval: 0.01)
      counter.leave()
    }
    let labels = (0..<60).map { "com.apple.l\($0)" }
    try simctl(host).applyDelta(
      set: "default", udid: udid, toDisable: labels, toEnable: [],
      disableAction: .overrideOnly, reporter: nil)
    XCTAssertEqual(host.disabled[udid], Set(labels))
    XCTAssertLessThanOrEqual(counter.peak, 8)
    XCTAssertGreaterThan(counter.peak, 1, "the pool really runs transitions concurrently")
  }

  func testApplyDeltaReportsProgress() throws {
    let host = host(state: "Booted")
    let lines = Log()
    let labels = (0..<45).map { "com.apple.l\($0)" }
    try simctl(host).applyDelta(
      set: "default", udid: udid, toDisable: labels, toEnable: [],
      disableAction: .overrideOnly, reporter: { lines.add($0) })
    XCTAssertEqual(
      lines.all,
      ["  20/45 services updated", "  40/45 services updated", "  45/45 services updated"])
  }

  // MARK: - deadline

  func testAnExpiredDeadlineRunsNothing() throws {
    let host = host()
    var ctl = simctl(host)
    ctl.deadline = Date(timeIntervalSinceNow: -1)
    XCTAssertThrowsError(try ctl.ensure(set: "default", udid: udid, desired: profileLabels)) {
      XCTAssertTrue("\($0)".contains("context deadline exceeded"), "\($0)")
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testDeadlineCapsEachCommandsTimeout() throws {
    let host = host(state: "Booted")
    var ctl = simctl(host)
    ctl.deadline = Date(timeIntervalSinceNow: 50)
    ctl.spawnTimeout = 120
    _ = try ctl.readDisabled(set: "default", udid: udid)
    let timeout = try XCTUnwrap(host.calls.last?.timeout)
    XCTAssertLessThanOrEqual(timeout, 50)
    XCTAssertGreaterThan(timeout, 40)
  }

  func testACommandKilledByTheDeadlineIsAnErrorNotAFailureToRetry() throws {
    struct Slow: CommandRunning {
      let clock: Clock
      func run(_ e: Executable, _ a: [String], timeout: TimeInterval?) throws -> CommandResult {
        clock.advance(100)  // the deadline passes while the command runs
        return CommandResult(status: -9, timedOut: true)
      }
    }
    let clock = Clock()
    var ctl = Simctl(runner: Slow(clock: clock))
    ctl.now = { clock.now }
    ctl.deadline = clock.now.addingTimeInterval(10)
    XCTAssertThrowsError(try ctl.shutdown(set: "default", udid: udid)) {
      XCTAssertEqual("\($0)", "context deadline exceeded")
    }
  }

  func testWaitShutdownTimesOut() throws {
    let host = host(state: "Booted")
    host.stuckBooted = true
    var ctl = simctl(host)
    let clock = Clock()
    ctl.now = { clock.now }
    ctl.sleep = { clock.advance($0) }
    XCTAssertThrowsError(try ctl.waitShutdown(set: "default", udid: udid, timeout: 30)) {
      XCTAssertEqual("\($0)", "timed out waiting for \(udid) to shut down")
    }
  }

  // MARK: - enableSlimNoReboot

  /// Creates job plists for `labels` under a fake RuntimeRoot, and registers them
  /// with the fake host. `mismatched` plists carry a different Label inside.
  private func installPlists(
    _ host: FakeHost, labels: [String], mismatched: Set<String> = [], missing: Set<String> = []
  ) throws {
    let dir = root + "/runtime/System/Library/LaunchDaemons"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    host.runtimeRoots[ios] = root + "/runtime"
    for label in labels where !missing.contains(label) {
      let path = "\(dir)/\(label).plist"
      FileManager.default.createFile(atPath: path, contents: Data())
      host.plistLabels[path] = mismatched.contains(label) ? "com.apple.other" : label
    }
  }

  func testNoRebootStopsLabelsInBatchesOfSixtyFour() throws {
    let host = host(state: "Booted")
    let labels = profileLabels.sorted()
    XCTAssertGreaterThan(labels.count, 128)
    host.loaded[udid] = Set(labels)
    try installPlists(host, labels: labels)

    let lines = Log()
    let changed = try simctl(host).enableSlimNoReboot(
      set: "default", udid: udid, profile: Profile(), reporter: { lines.add($0) })
    XCTAssertTrue(changed)
    let unloads = verbs(host).filter { $0.hasPrefix("spawn:unload -w") }
    XCTAssertEqual(unloads.count, (labels.count + 63) / 64)
    XCTAssertTrue(
      verbs(host).filter { $0.hasPrefix("spawn:disable ") || $0.hasPrefix("spawn:bootout ") }
        .isEmpty,
      "everything was stopped in the batch")
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), profileLabels)
    XCTAssertEqual(host.loaded[udid]?.intersection(profileLabels), [])
    XCTAssertTrue(
      lines.all.contains("  \(labels.count)/\(labels.count) services stopped in one batch"))
  }

  func testNoRebootNeverUnloadsAPlistWhoseLabelDiffers() throws {
    let host = host(state: "Booted")
    let labels = profileLabels.sorted()
    host.loaded[udid] = Set(labels)
    let impostor = labels[0]
    let absent = labels[1]
    try installPlists(host, labels: labels, mismatched: [impostor], missing: [absent])

    try simctl(host).enableSlimNoReboot(set: "default", udid: udid, profile: Profile())
    let batchArgs = host.calls.filter { $0.arguments.contains("unload") }.flatMap(\.arguments)
    XCTAssertFalse(batchArgs.contains { $0.hasSuffix("/\(impostor).plist") })
    XCTAssertFalse(batchArgs.contains { $0.hasSuffix("/\(absent).plist") })
    // They still end up stopped, through the per-label path.
    XCTAssertTrue(host.disabled[udid]!.isSuperset(of: [impostor, absent]))
    XCTAssertFalse(host.loaded[udid]!.contains(impostor))
    let perLabel = verbs(host).filter { $0.hasPrefix("spawn:bootout ") }
    XCTAssertEqual(
      Set(perLabel), ["spawn:bootout system/\(impostor)", "spawn:bootout system/\(absent)"])
  }

  func testNoRebootIsIdempotent() throws {
    let host = host(state: "Booted", disabled: profileLabels)
    host.loaded[udid] = []
    try installPlists(host, labels: profileLabels.sorted())
    let lines = Log()
    let changed = try simctl(host).enableSlimNoReboot(
      set: "default", udid: udid, profile: Profile(), reporter: { lines.add($0) })
    XCTAssertFalse(changed)
    XCTAssertTrue(transitions(host).isEmpty)
    XCTAssertTrue(lines.all.contains("  all \(profileLabels.count) services were already stopped"))
  }

  func testNoRebootStopsADisabledButStillLoadedJob() throws {
    // An earlier run disabled the job but failed to boot it out.
    let label = profileLabels.sorted()[0]
    let host = host(state: "Booted", disabled: profileLabels)
    host.loaded[udid] = [label]
    try installPlists(host, labels: [])
    let changed = try simctl(host).enableSlimNoReboot(
      set: "default", udid: udid, profile: Profile())
    XCTAssertFalse(changed, "nothing was newly disabled")
    XCTAssertEqual(host.loaded[udid], [])
    XCTAssertEqual(
      transitions(host), ["spawn:disable system/\(label)", "spawn:bootout system/\(label)"])
  }

  func testNoRebootLeavesExtraDisabledLabelsAlone() throws {
    var disabled = profileLabels
    let extra = Catalog.categories[0].labels[0]
    var profile = Profile()
    profile.keep = [extra]
    disabled = profile.desired().union([extra])  // slim, plus one the profile keeps enabled
    let host = host(state: "Booted", disabled: disabled)
    host.loaded[udid] = []
    let lines = Log()
    try simctl(host).enableSlimNoReboot(
      set: "default", udid: udid, profile: profile, reporter: { lines.add($0) })
    XCTAssertTrue(host.disabled[udid]!.contains(extra), "only `off` re-enables")
    XCTAssertTrue(lines.all.contains { $0.hasPrefix("Leaving 1 services disabled beyond") })
  }

  func testNoRebootReportsOverridesThatDidNotTake() throws {
    let host = host(state: "Booted")
    let victim = profileLabels.sorted()[0]
    host.loaded[udid] = []
    host.failTransition = { _, label in
      label == victim ? CommandResult(status: 1, stderr: Data("no".utf8)) : nil
    }
    XCTAssertThrowsError(
      try simctl(host).enableSlimNoReboot(set: "default", udid: udid, profile: Profile()))
  }
}

private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var t = Date(timeIntervalSince1970: 1_000_000)
  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return t
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    t = t.addingTimeInterval(seconds)
    lock.unlock()
  }
}
