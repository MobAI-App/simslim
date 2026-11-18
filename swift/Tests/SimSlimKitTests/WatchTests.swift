import TestSupport
import XCTest

@testable import SimSlimKit

private final class Events: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [WatchEvent] = []
  private var texts: [String] = []
  func add(_ event: WatchEvent) {
    lock.lock()
    items.append(event)
    lock.unlock()
  }
  func addText(_ text: String) {
    lock.lock()
    texts.append(text)
    lock.unlock()
  }
  var all: [WatchEvent] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
  var kinds: [String] { all.map(\.event) }
  var lines: [String] {
    lock.lock()
    defer { lock.unlock() }
    return texts
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
  func set() {
    lock.lock()
    value = true
    lock.unlock()
  }
}

private final class Calls: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ item: String) {
    lock.lock()
    items.append(item)
    lock.unlock()
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

final class WatchTests: XCTestCase {
  private let ios = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  private let old = "com.apple.CoreSimulator.SimRuntime.iOS-17-0"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-watch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private func udid(_ n: Int) -> String { String(format: "AAAAAAAA-0000-0000-0000-%012d", n) }

  private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
    let limit = Date().addingTimeInterval(timeout)
    while !condition() && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    XCTAssertTrue(condition(), "timed out waiting for \(what)")
  }

  private func makeWatcher(
    _ host: FakeHost, events: Events, slim: Watcher.Slimmer? = nil,
    preslim: Watcher.Preslimmer? = nil
  ) -> Watcher {
    var ctl = Simctl(runner: host)
    ctl.retryDelays = [0]
    ctl.sleep = { _ in }
    ctl.storeRoot = root + "/store"
    let watcher = Watcher(
      simctl: ctl, profile: Profile(), home: root + "/home",
      report: { events.addText($0) }, events: { events.add($0) })
    if let slim { watcher.slim = slim }
    watcher.preslim = preslim
    return watcher
  }

  private func booted(_ n: Int, runtime: String? = nil) -> FakeHost.FakeDevice {
    .init(udid: udid(n), name: "d\(n)", runtime: runtime ?? ios, state: "Booted")
  }

  private func shutdown(_ n: Int, runtime: String? = nil) -> FakeHost.FakeDevice {
    .init(udid: udid(n), name: "d\(n)", runtime: runtime ?? ios, state: "Shutdown")
  }

  // MARK: - after-boot passes

  func testABootedDeviceIsSlimmedOncePerBoot() {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let calls = Calls()
    let watcher = makeWatcher(
      host, events: events,
      slim: { _, set, id, _, _ in
        calls.add("\(set) \(id)")
        return true
      })
    watcher.scan()
    watcher.waitForWork()
    watcher.scan()
    watcher.waitForWork()
    XCTAssertEqual(calls.all, ["default \(udid(1))"], "the second scan leaves it alone")
    XCTAssertEqual(events.kinds, [WatchEventKind.slimming, WatchEventKind.slimmed])
    XCTAssertEqual(events.all[0], WatchEvent(event: "slimming", udid: udid(1), set: "default"))
  }

  func testAFailedPassIsRetriedByTheNextScan() {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let attempts = Calls()
    let watcher = makeWatcher(
      host, events: events,
      slim: { _, _, _, _, _ in
        attempts.add("x")
        if attempts.all.count == 1 { throw SimSlimError("transient launchctl failure") }
        return true
      })
    watcher.scan()
    watcher.waitForWork()
    XCTAssertEqual(events.kinds, ["slimming", "failed"])
    XCTAssertEqual(events.all[1].error, "transient launchctl failure")
    watcher.scan()
    watcher.waitForWork()
    XCTAssertEqual(events.kinds, ["slimming", "failed", "slimming", "slimmed"])
  }

  func testAPassIsCancelledWhenItsDeviceShutsDownAndNeverReportsSlimmed() {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let started = Flag()
    let watcher = makeWatcher(
      host, events: events,
      slim: { ctl, _, _, _, _ in
        started.set()
        while ctl.cancelled?() != true { Thread.sleep(forTimeInterval: 0.005) }
        throw SimSlimError("context canceled")
      })
    watcher.scan()
    waitFor("pass to start") { started.isSet }
    host.devices[0].state = "Shutdown"
    watcher.scan()
    watcher.waitForWork()
    XCTAssertEqual(events.kinds, ["slimming", "stopped"])
    XCTAssertFalse(events.kinds.contains("slimmed"))
    XCTAssertTrue(events.lines.contains("watch: \(udid(1)) shut down; stopped its slim"))
  }

  func testTheNextBootGetsAFreshPass() {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let watcher = makeWatcher(host, events: events, slim: { _, _, _, _, _ in true })
    watcher.scan()
    watcher.waitForWork()
    host.devices[0].state = "Shutdown"
    watcher.scan()
    host.devices[0].state = "Booted"
    watcher.scan()
    watcher.waitForWork()
    XCTAssertEqual(events.kinds, ["slimming", "slimmed", "slimming", "slimmed"])
  }

  func testADeletedDeviceCancelsItsPassAndIsForgotten() {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let started = Flag()
    let watcher = makeWatcher(
      host, events: events,
      slim: { ctl, _, _, _, _ in
        started.set()
        while ctl.cancelled?() != true { Thread.sleep(forTimeInterval: 0.005) }
        throw SimSlimError("context canceled")
      })
    watcher.scan()
    waitFor("pass to start") { started.isSet }
    host.devices = []
    watcher.scan()
    watcher.waitForWork()
    XCTAssertEqual(events.kinds, ["slimming", "stopped"])
  }

  func testEachDeviceSlimsInItsOwnThreadSoOneSlowPassDoesNotBlockTheOthers() {
    let host = FakeHost(devices: [booted(1), booted(2)])
    let events = Events()
    let release = Flag()
    let watcher = makeWatcher(
      host, events: events,
      slim: { _, _, id, _, _ in
        if id == "AAAAAAAA-0000-0000-0000-000000000001" {
          while !release.isSet { Thread.sleep(forTimeInterval: 0.005) }
        }
        return true
      })
    watcher.scan()
    waitFor("the fast device to finish") {
      events.all.contains { $0.event == "slimmed" && $0.udid == self.udid(2) }
    }
    XCTAssertFalse(events.all.contains { $0.event == "slimmed" && $0.udid == udid(1) })
    release.set()
    watcher.waitForWork()
    XCTAssertEqual(events.all.filter { $0.event == "slimmed" }.count, 2)
  }

  func testAFailedListingIsReportedAndTheLoopCarriesOn() {
    let host = FakeHost(devices: [booted(1)])
    host.listFailure = "CoreSimulatorService is not running"
    let events = Events()
    let watcher = makeWatcher(host, events: events)
    watcher.scan()
    XCTAssertTrue(events.lines.contains { $0.hasPrefix("watch: list devices: ") })
    XCTAssertEqual(events.kinds, [])
  }

  func testProgressLinesCarryTheUDID() {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let watcher = makeWatcher(
      host, events: events,
      slim: { _, _, _, _, reporter in
        reporter?("Stopping 173 background services")
        return true
      })
    watcher.scan()
    watcher.waitForWork()
    XCTAssertTrue(
      events.lines.contains("watch: \(udid(1)): Stopping 173 background services"))
  }

  // MARK: - slimming before boot

  func testAShutdownDeviceIsSeededOncePerShutdown() {
    let host = FakeHost(devices: [shutdown(1)])
    let events = Events()
    let seeds = Calls()
    let watcher = makeWatcher(
      host, events: events,
      preslim: { d, _ in
        seeds.add(d.udid)
        return 173
      })
    watcher.scan()
    watcher.scan()
    XCTAssertEqual(seeds.all, [udid(1)])
    XCTAssertEqual(
      events.all,
      [WatchEvent(event: "slimmed_before_boot", udid: udid(1), set: "default", services: 173)])
    // It boots (a booted device may rewrite its store), then shuts down again.
    host.devices[0].state = "Booted"
    watcher.scan()
    watcher.waitForWork()
    host.devices[0].state = "Shutdown"
    watcher.scan()
    XCTAssertEqual(seeds.all, [udid(1), udid(1)])
  }

  func testASeedThatFailsIsRetriedOnTheNextScan() {
    let host = FakeHost(devices: [shutdown(1)])
    let events = Events()
    let seeds = Calls()
    let watcher = makeWatcher(
      host, events: events,
      preslim: { _, _ in
        seeds.add("x")
        if seeds.all.count == 1 { throw SimSlimError("disk full") }
        return 5
      })
    watcher.scan()
    XCTAssertTrue(events.lines.contains("watch: \(udid(1)): slim before boot: disk full"))
    watcher.scan()
    XCTAssertEqual(events.kinds, ["slimmed_before_boot"])
  }

  func testASeedWithNothingToWriteIsSilent() {
    let host = FakeHost(devices: [shutdown(1)])
    let events = Events()
    let watcher = makeWatcher(host, events: events, preslim: { _, _ in 0 })
    watcher.scan()
    XCTAssertEqual(events.kinds, [])
    XCTAssertEqual(events.lines, [])
  }

  func testASeedThatLandsAfterTheBootBeganIsNotAnnounced() throws {
    let dir = root + "/devices/\(udid(1))"
    try FileManager.default.createDirectory(
      atPath: dir + "/data", withIntermediateDirectories: true)
    try devicePlist(udid: udid(1), runtime: ios, state: 3).write(
      toFile: dir + "/device.plist", atomically: true, encoding: .utf8)
    let events = Events()
    let watcher = makeWatcher(FakeHost(), events: events, preslim: { _, _ in 12 })
    var device = Device(
      udid: udid(1), state: "Shutdown", platform: "iOS", osVersion: "27.2", set: "default",
      dataPath: dir + "/data", runtimeID: ios)
    watcher.seed(device)
    XCTAssertEqual(events.kinds, [], "launchd_sim already started")
    XCTAssertTrue(
      events.lines.contains { $0.contains("booted before its slim (12 services) landed") })

    // The plist still says shut down: announced.
    try devicePlist(udid: udid(1), runtime: ios, state: 1).write(
      toFile: dir + "/device.plist", atomically: true, encoding: .utf8)
    device.udid = udid(2)
    watcher.seed(device)
    XCTAssertEqual(events.kinds, ["slimmed_before_boot"])
  }

  func testPreslimWritesOnlyMissingDisablesAndLeavesTheRestAlone() throws {
    let store = DisabledStore(root: root + "/store")
    let id = udid(1)
    try store.write(
      udid: id, toDisable: ["com.apple.unmanaged", "com.apple.extra.disabled"], toEnable: [])
    let someManaged = Profile().desired().sorted()[0]
    try store.write(udid: id, toDisable: [someManaged], toEnable: [])
    let device = Device(
      udid: id, state: "Shutdown", platform: "iOS", osVersion: "27.2", set: "default")
    let count = try preslimDevice(device, profile: Profile(), storeRoot: root + "/store")
    XCTAssertEqual(count, Profile().desired().count - 1)
    let disabled = try store.readDisabled(udid: id)
    XCTAssertTrue(disabled.isSuperset(of: Profile().desired()))
    XCTAssertTrue(disabled.contains("com.apple.unmanaged"), "unmanaged entries are untouched")
    XCTAssertEqual(try preslimDevice(device, profile: Profile(), storeRoot: root + "/store"), 0)
  }

  func testPreslimNeverEnablesAnything() throws {
    let store = DisabledStore(root: root + "/store")
    let id = udid(1)
    // Disabled beyond the profile: stays disabled.
    var profile = Profile()
    let kept = Catalog.categories[0].labels[0]
    profile.keep = [kept]
    try store.write(udid: id, toDisable: [kept], toEnable: [])
    let device = Device(
      udid: id, state: "Shutdown", platform: "iOS", osVersion: "27.2", set: "default")
    _ = try preslimDevice(device, profile: profile, storeRoot: root + "/store")
    XCTAssertTrue(try store.readDisabled(udid: id).contains(kept))
  }

  func testPreslimSkipsBootedDevicesAndRuntimesWithoutPersistence() throws {
    let booted = Device(
      udid: udid(1), state: "Booted", platform: "iOS", osVersion: "27.2", set: "default")
    let oldRuntime = Device(
      udid: udid(2), state: "Shutdown", platform: "iOS", osVersion: "17.0", set: "default")
    XCTAssertEqual(try preslimDevice(booted, profile: Profile(), storeRoot: root + "/store"), 0)
    XCTAssertEqual(try preslimDevice(oldRuntime, profile: Profile(), storeRoot: root + "/store"), 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/store"))
  }

  func testPreslimKeepsHomedEnabledOnWatchOS() throws {
    let watch = Device(
      udid: udid(1), state: "Shutdown", platform: "watchOS", osVersion: "11.5", set: "default")
    _ = try preslimDevice(watch, profile: Profile(), storeRoot: root + "/store")
    let disabled = try DisabledStore(root: root + "/store").readDisabled(udid: udid(1))
    XCTAssertFalse(disabled.contains("com.apple.homed"))
  }

  func testAReappearingUDIDIsSeededAgainBecauseDeletedDevicesAreForgotten() {
    let host = FakeHost(devices: [shutdown(1)])
    let seeds = Calls()
    let watcher = makeWatcher(
      host, events: Events(),
      preslim: { d, _ in
        seeds.add(d.udid)
        return 1
      })
    watcher.scan()
    host.devices = []
    watcher.scan()  // pruned
    host.devices = [shutdown(1)]
    watcher.scan()
    XCTAssertEqual(seeds.all, [udid(1), udid(1)])
  }

  func testABootedOrBootingDeviceIsNeverSeeded() {
    let seeds = Calls()
    let watcher = makeWatcher(
      FakeHost(), events: Events(),
      preslim: { d, _ in
        seeds.add(d.udid)
        return 1
      })
    for state in ["Booted", "Booting", "Shutting Down"] {
      watcher.seed(
        Device(udid: udid(1), state: state, platform: "iOS", osVersion: "27.2", set: "default"))
    }
    XCTAssertEqual(seeds.all, [])
  }

  func testACancelledOperationRunsNoCommand() {
    let host = FakeHost(devices: [booted(1)])
    var ctl = Simctl(runner: host)
    ctl.cancelled = { true }
    XCTAssertThrowsError(try ctl.readDisabled(set: "default", udid: udid(1))) {
      XCTAssertEqual("\($0)", "launchctl print-disabled: context canceled")
    }
    XCTAssertTrue(host.calls.isEmpty)
    // A slim stops at its next step, saying why.
    ctl.cancelled = { true }
    XCTAssertThrowsError(
      try ctl.applyDelta(
        set: "default", udid: udid(1), toDisable: ["com.apple.x"], toEnable: [],
        disableAction: .overrideOnly, reporter: nil)
    ) {
      XCTAssertTrue("\($0)".hasSuffix("context canceled"), "\($0)")
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  // MARK: - device.plist

  private func devicePlist(udid: String, runtime: String, state: Int, stateAsString: Bool = false)
    -> String
  {
    let value = stateAsString ? "<string>\(state)</string>" : "<integer>\(state)</integer>"
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <plist version="1.0"><dict>
      <key>UDID</key><string>\(udid)</string>
      <key>runtime</key><string>\(runtime)</string>
      <key>state</key>\(value)
      <key>name</key><string>iPhone</string>
      </dict></plist>
      """
  }

  func testReadDevicePlist() throws {
    let dir = root + "/dev"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (state, asString, expected) in [
      (1, false, "Shutdown"), (3, false, "Booted"), (1, true, "Shutdown"), (2, true, "Booted"),
    ] {
      try devicePlist(udid: udid(1), runtime: ios, state: state, stateAsString: asString)
        .write(toFile: dir + "/device.plist", atomically: true, encoding: .utf8)
      let device = try readDevicePlist(DeviceDir(path: dir, set: "testing"))
      XCTAssertEqual(device.state, expected)
      XCTAssertEqual(device.udid, udid(1))
      XCTAssertEqual(device.platform, "iOS")
      XCTAssertEqual(device.osVersion, "27.2")
      XCTAssertEqual(device.set, "testing")
      XCTAssertEqual(device.dataPath, dir + "/data")
      XCTAssertEqual(device.runtimeID, ios)
    }
  }

  func testReadDevicePlistRejectsWhatSimslimDoesNotSlim() throws {
    let dir = root + "/dev"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let cases = [
      devicePlist(
        udid: udid(1), runtime: "com.apple.CoreSimulator.SimRuntime.macOS-15-0", state: 1),
      devicePlist(udid: "", runtime: ios, state: 1),
      "not a plist",
    ]
    for text in cases {
      try text.write(toFile: dir + "/device.plist", atomically: true, encoding: .utf8)
      XCTAssertThrowsError(try readDevicePlist(DeviceDir(path: dir, set: "default")), text)
    }
    XCTAssertThrowsError(try readDevicePlist(DeviceDir(path: root + "/nowhere", set: "default")))
  }

  func testSeedNewWaitsForDevicePlistThenSeeds() throws {
    let dir = root + "/devices/\(udid(1))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let events = Events()
    let seeds = Calls()
    let watcher = makeWatcher(
      FakeHost(), events: events,
      preslim: { d, _ in
        seeds.add("\(d.udid) \(d.state) \(d.set)")
        return 1
      })
    let plist = devicePlist(udid: udid(1), runtime: ios, state: 1)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
      try? plist.write(toFile: dir + "/device.plist", atomically: true, encoding: .utf8)
    }
    watcher.seedNew(DeviceDir(path: dir, set: "default"))
    XCTAssertEqual(seeds.all, ["\(udid(1)) Shutdown default"])
  }

  func testSeedNewGivesUpOnADirectoryThatIsNotADevice() throws {
    let dir = root + "/devices/not-a-device"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let seeds = Calls()
    let watcher = makeWatcher(
      FakeHost(), events: Events(),
      preslim: { d, _ in
        seeds.add(d.udid)
        return 1
      })
    let started = Date()
    watcher.seedNew(DeviceDir(path: dir, set: "default"))
    XCTAssertEqual(seeds.all, [])
    XCTAssertLessThan(Date().timeIntervalSince(started), 4)
  }

  // MARK: - events and sets

  func testEventJSONLinesFollowTheGoFieldOrderAndOmitEmptyFields() {
    XCTAssertEqual(
      WatchEvent(event: "slimmed", udid: "U", set: "default").jsonLine,
      #"{"event":"slimmed","udid":"U","set":"default"}"#)
    XCTAssertEqual(
      WatchEvent(event: "slimmed_before_boot", udid: "U", set: "testing", services: 173).jsonLine,
      #"{"event":"slimmed_before_boot","udid":"U","set":"testing","services":173}"#)
    XCTAssertEqual(
      WatchEvent(event: "failed", udid: "U", set: "/a/b", error: "say \"no\"\nnow").jsonLine,
      #"{"event":"failed","udid":"U","set":"/a/b","error":"say \"no\"\nnow"}"#)
  }

  func testDeviceSetDirectories() {
    var ctl = Simctl(runner: FakeHost())
    ctl.registerDeviceSet("/custom/set")
    XCTAssertEqual(
      deviceSetDirs(ctl, home: "/Users/me"),
      [
        "/Users/me/Library/Developer/CoreSimulator/Devices": "default",
        "/Users/me/Library/Developer/XCTestDevices": "testing",
        "/custom/set": "/custom/set",
      ])
  }

  // MARK: - kqueue

  private func collect(
    _ dirs: [String: String], during body: () throws -> Void, expecting count: Int
  ) rethrows -> [DeviceDir] {
    let found = Calls()
    let stop = Flag()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      watchDeviceDirs(
        setDirs: dirs, pollInterval: 0.05, stop: { stop.isSet },
        created: { found.add($0.set + "|" + $0.path) })
      done.signal()
    }
    Thread.sleep(forTimeInterval: 0.2)  // let the baseline be taken
    try body()
    let limit = Date().addingTimeInterval(5)
    while found.all.count < count && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    Thread.sleep(forTimeInterval: 0.2)  // let anything unexpected show up
    stop.set()
    done.wait()
    return found.all.map { entry in
      let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
      return DeviceDir(path: parts[1], set: parts[0])
    }
  }

  func testKqueueReportsNewDeviceDirectoriesButNotTheBaseline() throws {
    let set = root + "/Devices"
    try FileManager.default.createDirectory(
      atPath: set + "/EXISTING", withIntermediateDirectories: true)
    let found = try collect(
      [set: "default"],
      during: {
        try FileManager.default.createDirectory(
          atPath: set + "/NEW-1", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: set + "/a-file", contents: Data())
      }, expecting: 1)
    XCTAssertEqual(found, [DeviceDir(path: set + "/NEW-1", set: "default")])
  }

  func testKqueueReportsABatchOfClones() throws {
    let set = root + "/Devices"
    try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
    let found = try collect(
      [set: "testing"],
      during: {
        for n in 0..<5 {
          try FileManager.default.createDirectory(
            atPath: set + "/CLONE-\(n)", withIntermediateDirectories: true)
        }
      }, expecting: 5)
    XCTAssertEqual(Set(found.map(\.path)), Set((0..<5).map { set + "/CLONE-\($0)" }))
    XCTAssertEqual(found.count, 5, "each directory is reported once")
  }

  func testKqueueAttachesASetDirectoryThatAppearsLater() throws {
    let set = root + "/XCTestDevices"
    let found = try collect(
      [set: "testing"],
      during: {
        try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.createDirectory(
          atPath: set + "/CLONE", withIntermediateDirectories: true)
      }, expecting: 1)
    XCTAssertTrue(found.contains(DeviceDir(path: set + "/CLONE", set: "testing")), "\(found)")
  }

  func testKqueueReattachesWhenTheSetDirectoryIsReplaced() throws {
    let set = root + "/Devices"
    try FileManager.default.createDirectory(atPath: set + "/OLD", withIntermediateDirectories: true)
    let found = try collect(
      [set: "default"],
      during: {
        try FileManager.default.removeItem(atPath: set)
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.createDirectory(
          atPath: set + "/FRESH", withIntermediateDirectories: true)
      }, expecting: 1)
    XCTAssertTrue(found.contains(DeviceDir(path: set + "/FRESH", set: "default")), "\(found)")
  }

  func testKqueueReportsADeletedAndRecreatedDeviceAgain() throws {
    let set = root + "/Devices"
    try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
    let found = try collect(
      [set: "default"],
      during: {
        try FileManager.default.createDirectory(
          atPath: set + "/X", withIntermediateDirectories: true)
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.removeItem(atPath: set + "/X")
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.createDirectory(
          atPath: set + "/X", withIntermediateDirectories: true)
      }, expecting: 2)
    XCTAssertEqual(found.count, 2)
  }

  func testKqueueStopsPromptly() {
    let stop = Flag()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      watchDeviceDirs(setDirs: [:], pollInterval: 0.05, stop: { stop.isSet }, created: { _ in })
      done.signal()
    }
    stop.set()
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
  }

  // MARK: - run

  func testRunSlimsABootedDeviceAndAFreshCloneThenStops() throws {
    let home = root + "/home"
    let devices = home + "/Library/Developer/CoreSimulator/Devices"
    try FileManager.default.createDirectory(atPath: devices, withIntermediateDirectories: true)
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let seeds = Calls()
    let watcher = makeWatcher(
      host, events: events, slim: { _, _, _, _, _ in true },
      preslim: { d, _ in
        seeds.add(d.udid)
        return 3
      })
    let stop = Flag()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      watcher.run(interval: 0.2, stop: { stop.isSet })
      finished.signal()
    }
    waitFor("the booted device to be slimmed") { events.kinds.contains("slimmed") }

    // `simctl create` makes the directory, then writes device.plist.
    let clone = devices + "/\(udid(9))"
    try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
    try devicePlist(udid: udid(9), runtime: ios, state: 1)
      .write(toFile: clone + "/device.plist", atomically: true, encoding: .utf8)
    waitFor("the new device to be seeded before any scan lists it") {
      seeds.all.contains(self.udid(9))
    }
    waitFor("the seed to be announced") {
      events.all.contains { $0.event == "slimmed_before_boot" && $0.udid == self.udid(9) }
    }

    stop.set()
    XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "run returns once stopped")
  }

  func testRunReturnsOnlyAfterItsSlimsHaveStopped() throws {
    let host = FakeHost(devices: [booted(1)])
    let events = Events()
    let started = Flag()
    let exited = Flag()
    let watcher = makeWatcher(
      host, events: events,
      slim: { ctl, _, _, _, _ in
        started.set()
        while ctl.cancelled?() != true { Thread.sleep(forTimeInterval: 0.005) }
        Thread.sleep(forTimeInterval: 0.2)
        exited.set()
        throw SimSlimError("context canceled")
      })
    let stop = Flag()
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      watcher.run(interval: 0.2, stop: { stop.isSet })
      XCTAssertTrue(exited.isSet, "no slim outlives the call")
      finished.signal()
    }
    waitFor("the slim to start") { started.isSet }
    stop.set()
    XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
  }
}
