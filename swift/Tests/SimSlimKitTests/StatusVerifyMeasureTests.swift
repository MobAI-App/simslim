// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import TestSupport
import XCTest

@testable import SimSlimKit

final class StatusTests: XCTestCase {
  func testSupportsPersistentOverrides() {
    let cases: [(String, String, Bool)] = [
      ("iOS", "18.5", true), ("iOS", "18.4", false), ("iOS", "18.3", false),
      ("iOS", "19.0", true), ("iOS", "27.2", true), ("iOS", "17.9", false),
      ("iOS", "18", false), ("iOS", "", false), ("iOS", "x.y", false), ("iOS", "18.5.1", true),
      ("", "18.5", true),  // empty platform defaults to iOS
      ("tvOS", "18.5", true), ("tvOS", "18.4", false),
      ("watchOS", "11.5", true), ("watchOS", "11.4", false), ("watchOS", "12.0", true),
      ("watchOS", "18.5", true),
      ("visionOS", "2.5", true), ("visionOS", "2.4", false), ("visionOS", "3.0", true),
      ("macOS", "99.9", false),
    ]
    for (platform, version, expected) in cases {
      let device = Device(udid: "U", platform: platform, osVersion: version)
      XCTAssertEqual(
        device.supportsPersistentOverrides, expected, "\(platform) \(version)")
    }
  }

  func testMinimumPersistentVersionMatchesTheGate() {
    XCTAssertEqual(Device(udid: "U", platform: "watchOS").minimumPersistentVersion, "11.5")
    XCTAssertEqual(Device(udid: "U", platform: "visionOS").minimumPersistentVersion, "2.5")
    XCTAssertEqual(Device(udid: "U", platform: "iOS").minimumPersistentVersion, "18.5")
    XCTAssertEqual(Device(udid: "U", platform: "tvOS").minimumPersistentVersion, "18.5")
  }

  func testVerdict() {
    func verdict(_ disabled: Int, _ total: Int) -> String {
      Status(managedDisabled: disabled, managedTotal: total, booted: true, persistent: true).verdict
    }
    XCTAssertEqual(verdict(0, 173), "stock")
    XCTAssertEqual(verdict(1, 173), "partially slim")
    XCTAssertEqual(verdict(172, 173), "partially slim")
    XCTAssertEqual(verdict(173, 173), "slim")
  }

  func testInitialStatusUsesThePlatformSpecificTotal() {
    let ios = Status.initial(
      for: Device(udid: "U", state: "Booted", platform: "iOS", osVersion: "27.2"))
    let watch = Status.initial(for: Device(udid: "U", platform: "watchOS", osVersion: "11.5"))
    XCTAssertEqual(ios.managedTotal, 173)
    XCTAssertEqual(watch.managedTotal, 172, "homed stays enabled on watchOS")
    XCTAssertTrue(ios.booted)
    XCTAssertFalse(watch.booted)
    XCTAssertTrue(ios.persistent)
  }

  func testReadStatusCountsOnlyManagedLabels() throws {
    let host = FakeHost(devices: [.init(udid: "U", name: "n", state: "Booted")])
    host.disabled["U"] = [
      "com.apple.apsd",  // managed
      "com.apple.searchd",  // managed
      "com.apple.sharingd",  // managed (always-enabled): a legacy disable counts as managed
      "com.apple.nanoregistryd",  // forbidden and unmanaged
      "com.apple.not-ours",
    ]
    let (status, disabled) = try Simctl(runner: host).readStatus(udid: "U")
    XCTAssertEqual(status.managedDisabled, 2, "only labels in the full slim set count")
    XCTAssertEqual(disabled.count, 5, "the raw disabled set is returned unfiltered")
  }

  func testReadStatusRequiresABootedDevice() {
    let host = FakeHost(devices: [.init(udid: "U", name: "n", state: "Shutdown")])
    XCTAssertThrowsError(try Simctl(runner: host).readStatus(udid: "U")) { error in
      XCTAssertEqual(
        (error as? SimSlimError)?.message,
        "simulator must be booted to read its state (it is Shutdown)")
    }
    XCTAssertFalse(
      host.calls.contains { $0.arguments.contains("spawn") }, "no spawn into a shutdown device")
  }

  func testDroppedCategoriesAreGroupedInCategoryOrder() {
    let dropped = Catalog.droppedCategories(disabled: [
      "com.apple.searchd", "com.apple.PosterBoard", "com.apple.chronod", "com.apple.not-ours",
    ])
    XCTAssertEqual(dropped.map(\.id), ["widgets", "search"], "category order, not label order")
    XCTAssertEqual(dropped[0].labels, ["com.apple.PosterBoard", "com.apple.chronod"])
    XCTAssertEqual(Catalog.droppedCategories(disabled: []), [])
    XCTAssertEqual(Catalog.droppedCategories(disabled: ["com.apple.not-ours"]), [])
  }
}

final class VerifyTests: XCTestCase {
  func testCompareDisabled() {
    let managed: Set<String> = ["a", "b", "c", "d"]
    let result = compareDisabled(
      disabled: ["a", "d", "zzz"], desired: ["a", "b"], managed: managed)
    XCTAssertFalse(result.ok)
    XCTAssertEqual(result.missing, ["b"])
    XCTAssertEqual(result.extra, ["d"], "unmanaged 'zzz' never counts as drift")

    let match = compareDisabled(
      disabled: ["a", "b", "zzz"], desired: ["a", "b"], managed: managed)
    XCTAssertTrue(match.ok)
    XCTAssertTrue(match.missing.isEmpty && match.extra.isEmpty)
  }

  func testVerifyAgainstTheFullProfile() throws {
    let host = FakeHost(devices: [.init(udid: "U", name: "n", state: "Booted")])
    host.disabled["U"] = Profile().desired()
    let simctl = Simctl(runner: host)
    let ok = try simctl.verifyProfile(udid: "U", profile: Profile())
    XCTAssertTrue(ok.ok)
    XCTAssertEqual(ok.udid, "U")

    host.disabled["U"] = Profile().desired().subtracting(["com.apple.apsd"])
    let drift = try simctl.verifyProfile(udid: "U", profile: Profile())
    XCTAssertFalse(drift.ok)
    XCTAssertEqual(drift.missing, ["com.apple.apsd"])
  }

  func testVerifyUsesThePlatformSpecificDesiredSet() throws {
    // On watchOS homed must stay enabled, so a device that is slim except for homed matches.
    let watch = "com.apple.CoreSimulator.SimRuntime.watchOS-11-5"
    let host = FakeHost(devices: [.init(udid: "W", name: "w", runtime: watch, state: "Booted")])
    host.disabled["W"] = Profile().desired().subtracting(["com.apple.homed"])
    XCTAssertTrue(try Simctl(runner: host).verifyProfile(udid: "W", profile: Profile()).ok)
  }

  func testVerifyRequiresBooted() {
    let host = FakeHost(devices: [.init(udid: "U", name: "n")])
    XCTAssertThrowsError(try Simctl(runner: host).verifyProfile(udid: "U", profile: Profile()))
  }

  func testVerifyResultOmitsEmptyLists() throws {
    let data = try JSONEncoder().encode(VerifyResult(udid: "U", ok: true, missing: [], extra: []))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["udid", "ok"])
  }
}

final class MeasureTests: XCTestCase {
  func testParseBytes() {
    let cases: [(String, Int64)] = [
      ("45M", 45 * 1_048_576), ("45M+", 45 * 1_048_576), ("45M-", 45 * 1_048_576),
      ("1.5G", 1_610_612_736), ("900K", 900 * 1024), ("12B", 12), ("12", 12), ("0", 0),
      ("", 0), ("+", 0), ("abc", 0), ("1.5.2M", 0), ("1e30", 0), ("1e30G", 0), ("1e400", 0),
    ]
    for (text, expected) in cases {
      XCTAssertEqual(Simctl.parseBytes(text), expected, "parseBytes(\"\(text)\")")
    }
  }

  func testParseTopMemory() {
    let output = """
      Processes: 400 total, 3 running
      Load Avg: 1.0, 1.0, 1.0
      PID    MEM
      101    45M
      102    1.5G+
      103    900K-
      104    12B
      abc    5M
      105    notasize
      7
      """
    XCTAssertEqual(
      Simctl.parseTopMemory(output),
      [101: 45 * 1_048_576, 102: 1_610_612_736, 103: 900 * 1024, 104: 12] as [Int: Int64])
  }

  func testParsePSKeepsParentLinksCPUAndBasename() {
    let output = """
        PID  PPID  %CPU COMM
          1     0   0.0 /sbin/launchd
        200     1   1.5 /Library/Developer/CoreSimulator/Volumes/iOS 27.2/launchd_sim
        201   200  12.5 /Applications/Xcode.app/Contents/Developer/SpringBoard
        202   200   0.0 backboardd
      garbage line
      """
    let snapshot = Simctl.parsePS(output)
    XCTAssertEqual(snapshot.children[200], [201, 202])
    XCTAssertEqual(snapshot.cpu[201], 12.5)
    XCTAssertEqual(snapshot.comm[200], "launchd_sim", "spaces in the path are tolerated")
    XCTAssertEqual(snapshot.comm[201], "SpringBoard")
    XCTAssertEqual(snapshot.comm[202], "backboardd")
    XCTAssertNil(snapshot.comm[0])
  }

  func testTreePIDsCoversTheWholeTreeOnlyAndSurvivesCycles() {
    let children = [1: [2, 3], 2: [4], 3: [], 9: [10], 4: [2]]  // 4 -> 2 is a cycle
    XCTAssertEqual(Simctl.treePIDs(root: 1, children: children), [1, 2, 3, 4])
    XCTAssertEqual(Simctl.treePIDs(root: 9, children: children), [9, 10])
    XCTAssertEqual(Simctl.treePIDs(root: 77, children: children), [77])
  }

  private func host() -> FakeHost {
    let host = FakeHost()
    host.launchdPIDs = ["AAAA": 200, "BBBB": 300]
    host.psOutput = """
        PID  PPID  %CPU COMM
        200     1   1.0 /x/launchd_sim
        201   200   2.0 /x/SpringBoard
        300     1   4.0 /x/launchd_sim
        301   300   0.5 /x/backboardd
        999     1  50.0 /x/unrelated
      """
    host.topOutput = """
      PID    MEM
      200    10M
      201    20M
      300    1G
      301    5M
      999    100M
      """
    return host
  }

  func testMeasureSumsOnlyThatSimulatorsTree() throws {
    let measurement = try Simctl(runner: host()).measure(udid: "AAAA")
    XCTAssertEqual(measurement.processes, 2)
    XCTAssertEqual(measurement.bytes, 30 * 1_048_576)
    XCTAssertEqual(measurement.cpu, 3.0, accuracy: 0.0001)
  }

  func testMeasureManyTakesOneSnapshotAndReportsPerDeviceErrors() {
    let fake = host()
    let (measurements, errors) = Simctl(runner: fake).measureMany(udids: ["AAAA", "BBBB", "CCCC"])
    XCTAssertEqual(measurements["AAAA"]?.bytes, 30 * 1_048_576)
    XCTAssertEqual(measurements["BBBB"]?.bytes, 1_073_741_824 + 5 * 1_048_576)
    XCTAssertNil(measurements["CCCC"])
    XCTAssertEqual(errors["CCCC"], "simulator CCCC does not appear to be booted")
    XCTAssertEqual(fake.calls.filter { $0.executable == .ps }.count, 1, "one ps for every device")
    XCTAssertEqual(fake.calls.filter { $0.executable == .top }.count, 1, "one top for every device")
  }

  func testMeasureManyWithNothingBootedSpawnsNoPsOrTop() {
    let fake = FakeHost()
    let (measurements, errors) = Simctl(runner: fake).measureMany(udids: ["X"])
    XCTAssertTrue(measurements.isEmpty)
    XCTAssertEqual(errors.count, 1)
    XCTAssertFalse(fake.calls.contains { $0.executable == .ps || $0.executable == .top })
  }

  func testMeasureOfANotBootedSimulatorFails() {
    XCTAssertThrowsError(try Simctl(runner: FakeHost()).measure(udid: "X")) { error in
      XCTAssertEqual(
        (error as? SimSlimError)?.message, "simulator X does not appear to be booted")
    }
  }

  func testPgrepMatchesTheBootstrapPath() throws {
    let fake = host()
    _ = try Simctl(runner: fake).measure(udid: "AAAA")
    let pgrep = try XCTUnwrap(fake.calls.first { $0.executable == .pgrep })
    XCTAssertEqual(pgrep.arguments, ["-f", "AAAA/data/var/run/launchd_bootstrap"])
  }

  func testMemoryMeasurementJSONKeys() throws {
    let data = try JSONEncoder().encode(MemoryMeasurement(processes: 2, bytes: 3, cpu: 1.5))
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(Set(object.keys), ["processes", "bytes", "cpu"])
  }
}
