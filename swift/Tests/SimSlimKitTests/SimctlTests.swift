// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import TestSupport
import XCTest

@testable import SimSlimKit

final class SimctlTests: XCTestCase {
  private let ios = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  private let tvos = "com.apple.CoreSimulator.SimRuntime.tvOS-27-2"
  private let xros = "com.apple.CoreSimulator.SimRuntime.xrOS-27-2"

  // MARK: - parseRuntime

  func testParseRuntime() {
    let cases: [(String, String?, String?)] = [
      ("com.apple.CoreSimulator.SimRuntime.iOS-27-2", "iOS", "27.2"),
      ("com.apple.CoreSimulator.SimRuntime.iOS-18-5", "iOS", "18.5"),
      ("com.apple.CoreSimulator.SimRuntime.tvOS-26-5", "tvOS", "26.5"),
      ("com.apple.CoreSimulator.SimRuntime.watchOS-11-5", "watchOS", "11.5"),
      ("com.apple.CoreSimulator.SimRuntime.xrOS-2-5", "visionOS", "2.5"),
      ("com.apple.CoreSimulator.SimRuntime.iOS-17-0-1", "iOS", "17.0.1"),
      ("com.apple.CoreSimulator.SimRuntime.macOS-15-0", nil, nil),
      ("com.apple.CoreSimulator.SimRuntime.iOS", nil, nil),
      ("com.apple.CoreSimulator.SimRuntime.iOS-", nil, nil),
      ("something.else.iOS-27-2", nil, nil),
      ("", nil, nil),
    ]
    for (runtime, platform, version) in cases {
      let parsed = Simctl.parseRuntime(runtime)
      XCTAssertEqual(parsed?.platform, platform, runtime)
      XCTAssertEqual(parsed?.version, version, runtime)
    }
  }

  // MARK: - parseDisabled

  func testParseDisabled() {
    let output = """
      disabled services = {
      \t"com.apple.a" => disabled
      \t"com.apple.b" => enabled
      \t"com.apple.c" => true
      \t"com.apple.d" => false
      \t"com.apple.e"=>disabled
      \tno quotes => disabled
      \t"unterminated => disabled
      \t"com.apple.f" disabled
      }
      """
    XCTAssertEqual(Simctl.parseDisabled(output), ["com.apple.a", "com.apple.c", "com.apple.e"])
    XCTAssertEqual(Simctl.parseDisabled(""), [])
  }

  // MARK: - listing

  func testListDevicesFiltersAndMapsFields() throws {
    let host = FakeHost(devices: [
      .init(udid: "A", name: "iPhone", state: "Booted"),
      .init(udid: "B", name: "iPad"),
      .init(udid: "C", name: "Gone", isAvailable: false),
      .init(udid: "D", name: "TV", runtime: tvos),
      .init(udid: "E", name: "Vision", runtime: xros),
      .init(udid: "F", name: "Mac", runtime: "com.apple.CoreSimulator.SimRuntime.macOS-15-0"),
    ])
    let devices = try Simctl(runner: host).listDevices()
    XCTAssertEqual(
      Set(devices.map(\.udid)), ["A", "B", "D", "E"], "unavailable and unsupported dropped")

    let iphone = try XCTUnwrap(devices.first { $0.udid == "A" })
    XCTAssertEqual(iphone.name, "iPhone")
    XCTAssertEqual(iphone.state, "Booted")
    XCTAssertEqual(iphone.platform, "iOS")
    XCTAssertEqual(iphone.osVersion, "27.2")
    XCTAssertEqual(iphone.set, "default")
    XCTAssertEqual(iphone.runtimeID, ios)
    XCTAssertEqual(iphone.dataPath, "/fake/A/data")
    XCTAssertEqual(devices.first { $0.udid == "E" }?.platform, "visionOS")
  }

  func testListDevicesTreatsMissingIsAvailableAsUnavailable() throws {
    // Like the Go tool: an entry without isAvailable is not listed.
    final class Raw: CommandRunning, @unchecked Sendable {
      func run(_ e: Executable, _ a: [String], timeout: TimeInterval?) throws -> CommandResult {
        let json =
          #"{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-2":[{"udid":"X","name":"n","state":"Shutdown"}]}}"#
        return CommandResult(status: 0, stdout: Data(json.utf8))
      }
    }
    XCTAssertTrue(try Simctl(runner: Raw()).listDevices().isEmpty)
  }

  func testDefaultSetFailureIsFatalWithStderrAndHint() {
    let host = FakeHost()
    host.listFailure =
      "xcrun: error: unable to find utility \"simctl\", not a developer tool or in PATH"
    XCTAssertThrowsError(try Simctl(runner: host).listDevices()) { error in
      let message = (error as? SimSlimError)?.message ?? ""
      XCTAssertTrue(message.hasPrefix("simctl list: exit status 1: xcrun: error"), message)
      XCTAssertTrue(
        message.contains("select one with `sudo xcode-select -s /Applications/Xcode.app`"), message)
    }
    host.listFailure = "boom"
    XCTAssertThrowsError(try Simctl(runner: host).listDevices()) { error in
      XCTAssertEqual((error as? SimSlimError)?.message, "simctl list: exit status 1: boom")
    }
  }

  func testSecondarySetThatCannotBeListedIsSkipped() throws {
    let host = FakeHost(devices: [.init(udid: "A", name: "default one")])
    var simctl = Simctl(runner: host)
    simctl.registerDeviceSet("/no/such/set")
    let devices = try simctl.listDevices()
    XCTAssertEqual(devices.map(\.udid), ["A"])
  }

  func testExtraAndTestingSetsAreScanned() throws {
    let host = FakeHost(devices: [.init(udid: "A", name: "d")])
    host.sets["testing"] = [.init(udid: "T", name: "clone")]
    host.sets["/custom"] = [.init(udid: "C", name: "custom")]
    var simctl = Simctl(runner: host)
    simctl.registerDeviceSet("/custom")
    let devices = try simctl.listDevices()
    XCTAssertEqual(Set(devices.map(\.udid)), ["A", "T", "C"])
    XCTAssertEqual(devices.first { $0.udid == "T" }?.set, "testing")
    XCTAssertEqual(devices.first { $0.udid == "C" }?.set, "/custom")
  }

  func testRegisterDeviceSetIgnoresDuplicatesAndKnownTokens() {
    var simctl = Simctl(runner: FakeHost())
    simctl.registerDeviceSet("testing")
    simctl.registerDeviceSet("/x")
    simctl.registerDeviceSet("/x")
    XCTAssertEqual(simctl.extraSets, ["/x"])
    XCTAssertEqual(simctl.knownSets.map(\.token), ["", "testing", "/x"])
  }

  func testSimctlArgsPutSetBeforeTheSubcommand() {
    var simctl = Simctl(runner: FakeHost())
    simctl.registerDeviceSet("/x")
    XCTAssertEqual(simctl.simctlArgs(set: "default", ["list"]), ["simctl", "list"])
    XCTAssertEqual(
      simctl.simctlArgs(set: "testing", ["list"]), ["simctl", "--set", "testing", "list"])
    XCTAssertEqual(simctl.simctlArgs(set: "/x", ["list"]), ["simctl", "--set", "/x", "list"])
    XCTAssertEqual(simctl.simctlArgs(set: "unknown", ["list"]), ["simctl", "list"])
  }

  func testFindDevice() throws {
    let host = FakeHost(devices: [.init(udid: "A", name: "d")])
    host.sets["testing"] = [.init(udid: "T", name: "clone")]
    let simctl = Simctl(runner: host)
    XCTAssertEqual(try simctl.findDevice(udid: "A").set, "default")
    XCTAssertEqual(try simctl.findDevice(udid: "T").set, "testing")
    XCTAssertThrowsError(try simctl.findDevice(udid: "nope")) { error in
      XCTAssertEqual((error as? SimSlimError)?.message, "no simulator with udid nope")
    }
    // A named set looks only there.
    XCTAssertThrowsError(try simctl.findDevice(udid: "A", set: "testing"))
    XCTAssertEqual(try simctl.findDevice(udid: "T", set: "testing").udid, "T")
  }

  func testFindDeviceNeverMatchesAnAlias() {
    // `simctl` accepts aliases like "all" and "booted"; a lookup by UDID must not.
    let host = FakeHost(devices: [.init(udid: "A", name: "d", state: "Booted")])
    for alias in ["all", "booted", "available", ""] {
      XCTAssertThrowsError(try Simctl(runner: host).findDevice(udid: alias), alias)
    }
  }

  // MARK: - reading launchd, with retries

  private func settling() -> CommandResult {
    CommandResult(status: 124, stderr: Data("launchctl: Domain is tearing down".utf8))
  }

  private func slept(_ simctl: inout Simctl) -> SleepLog {
    let log = SleepLog()
    simctl.sleep = { log.record($0) }
    return log
  }

  func testReadDisabledPassesTheSpawnTimeoutAndArguments() throws {
    let host = FakeHost()
    host.disabled["U"] = ["com.apple.apsd"]
    var simctl = Simctl(runner: host)
    simctl.spawnTimeout = 77
    XCTAssertEqual(try simctl.readDisabled(set: "default", udid: "U"), ["com.apple.apsd"])
    let call = try XCTUnwrap(host.calls.last)
    XCTAssertEqual(
      call.arguments, ["simctl", "spawn", "U", "launchctl", "print-disabled", "system"])
    XCTAssertEqual(call.timeout, 77)
  }

  func testReadLaunchdRetriesErrorOneTwentyFourWithBackoff() throws {
    let host = FakeHost()
    host.disabled["U"] = ["com.apple.apsd"]
    host.queueSpawnResults(udid: "U", [settling(), settling()])
    var simctl = Simctl(runner: host)
    let log = slept(&simctl)
    XCTAssertEqual(try simctl.readDisabled(set: "default", udid: "U"), ["com.apple.apsd"])
    XCTAssertEqual(log.values, [1, 2], "waits the first two retry delays")
    XCTAssertEqual(host.calls.count, 3)
  }

  func testReadLaunchdRecognizesSettlingByTextToo() throws {
    let host = FakeHost()
    host.disabled["U"] = []
    host.queueSpawnResults(
      udid: "U", [CommandResult(status: 1, stderr: Data("xpc error code=124".utf8))])
    var simctl = Simctl(runner: host)
    _ = slept(&simctl)
    XCTAssertNoThrow(try simctl.readDisabled(set: "default", udid: "U"))
    XCTAssertEqual(host.calls.count, 2)
  }

  func testReadLaunchdGivesUpAfterTheLastDelay() {
    let host = FakeHost()
    host.disabled["U"] = []
    host.queueSpawnResults(udid: "U", Array(repeating: settling(), count: 10))
    var simctl = Simctl(runner: host)
    let log = slept(&simctl)
    XCTAssertThrowsError(try simctl.readDisabled(set: "default", udid: "U")) { error in
      let message = (error as? SimSlimError)?.message ?? ""
      XCTAssertTrue(message.hasPrefix("launchctl print-disabled: exit status 124:"), message)
      XCTAssertTrue(message.contains("Domain is tearing down"), message)
    }
    XCTAssertEqual(log.values, [1, 2, 4, 8])
    XCTAssertEqual(host.calls.count, 5, "the first attempt plus one per delay")
  }

  func testReadLaunchdDoesNotRetryOtherFailures() {
    let host = FakeHost()
    host.disabled["U"] = []
    host.queueSpawnResults(
      udid: "U", [CommandResult(status: 2, stderr: Data("permission denied".utf8))])
    var simctl = Simctl(runner: host)
    let log = slept(&simctl)
    XCTAssertThrowsError(try simctl.readDisabled(set: "default", udid: "U"))
    XCTAssertEqual(log.values, [])
    XCTAssertEqual(host.calls.count, 1)
  }

  func testReadLaunchdRetriesATimedOutAttempt() throws {
    let host = FakeHost()
    host.disabled["U"] = ["com.apple.apsd"]
    host.queueSpawnResults(udid: "U", [CommandResult(status: -9, timedOut: true)])
    var simctl = Simctl(runner: host)
    let log = slept(&simctl)
    XCTAssertEqual(try simctl.readDisabled(set: "default", udid: "U"), ["com.apple.apsd"])
    XCTAssertEqual(log.values, [1])
  }

  func testTimedOutErrorMessageSaysSo() {
    let host = FakeHost()
    host.queueSpawnResults(
      udid: "U", Array(repeating: CommandResult(status: -9, timedOut: true), count: 5))
    var simctl = Simctl(runner: host)
    simctl.spawnTimeout = 90
    _ = slept(&simctl)
    XCTAssertThrowsError(try simctl.readDisabled(set: "default", udid: "U")) { error in
      XCTAssertTrue(
        ((error as? SimSlimError)?.message ?? "").hasPrefix(
          "launchctl print-disabled: timed out after 90s"))
    }
  }

  func testReadLaunchdOnANonDefaultSetTargetsIt() throws {
    let host = FakeHost()
    host.disabled["U"] = []
    var simctl = Simctl(runner: host)
    simctl.registerDeviceSet("testing")
    _ = try simctl.readDisabled(set: "testing", udid: "U")
    XCTAssertEqual(
      host.calls.last?.arguments,
      ["simctl", "--set", "testing", "spawn", "U", "launchctl", "print-disabled", "system"])
  }
}

/// Records the pauses a retry loop asked for, without actually sleeping.
final class SleepLog: @unchecked Sendable {
  private let lock = NSLock()
  private var _values: [TimeInterval] = []
  func record(_ value: TimeInterval) {
    lock.lock()
    _values.append(value)
    lock.unlock()
  }
  var values: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return _values
  }
}
