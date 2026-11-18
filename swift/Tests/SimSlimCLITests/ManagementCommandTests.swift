// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class ManagementCommandTests: XCTestCase {
  fileprivate let udid = "AAAAAAAA-0000-0000-0000-000000000001"

  fileprivate func host(state: String = "Shutdown") -> FakeHost {
    FakeHost(devices: [.init(udid: udid, name: "Old name", state: state)])
  }

  fileprivate func subcommands(_ host: FakeHost) -> [String] {
    host.calls.compactMap { $0.executable == .xcrun ? $0.arguments.dropFirst().first : nil }
  }

  // MARK: - rename

  func testRenameTrimsAndReports() {
    let host = host()
    let r = runCLI(["rename", udid, "  Test \"Phone\"  "], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Renamed \(udid) to \"Test \\\"Phone\\\"\".\n")
    XCTAssertEqual(host.devices[0].name, "Test \"Phone\"")
  }

  func testRenameJSON() throws {
    let r = runCLI(["rename", udid, "New", "--json"], host: host())
    XCTAssertEqual(r.status, 0, r.stderr)
    let out = try JSONDecoder().decode(SimulatorMutationOutput.self, from: Data(r.stdout.utf8))
    XCTAssertEqual(out, SimulatorMutationOutput(action: "rename", udid: udid, name: "New"))
  }

  func testRenameRejectsBadNamesBeforeAnyCommand() {
    let tooLong = String(repeating: "x", count: 129)
    for (name, message) in [
      ("   ", "simulator name cannot be empty"),
      (tooLong, "simulator name cannot exceed 128 characters"),
      ("a\u{0007}b", "simulator name cannot contain control characters"),
      ("a\nb", "simulator name cannot contain control characters"),
    ] {
      let host = host()
      let r = runCLI(["rename", udid, name], host: host)
      XCTAssertEqual(r.status, 1, name)
      XCTAssertEqual(r.stderr, "simslim: \(message)\n", name)
      XCTAssertFalse(subcommands(host).contains("rename"), name)
    }
    let ok = String(repeating: "é", count: 128)
    XCTAssertEqual(runCLI(["rename", udid, ok], host: host()).status, 0, "128 characters is fine")
  }

  func testRenameNeedsExactlyTwoArgumentsAndAnExactUDID() {
    XCTAssertEqual(
      runCLI(["rename", udid], host: host()).stderr,
      "simslim: rename expects a simulator UDID and a new name\n")
    XCTAssertEqual(runCLI(["rename", udid, "a", "b"], host: host()).status, 1)
    let host = host()
    XCTAssertEqual(runCLI(["rename", "all", "X"], host: host).status, 1)
    XCTAssertFalse(subcommands(host).contains("rename"))
  }

  // MARK: - erase / delete

  func testEraseShutsDownABootedSimulatorFirst() {
    let host = host(state: "Booted")
    let r = runCLI(["erase", udid], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Erased simulator \(udid).\n")
    let verbs = subcommands(host)
    let shutdown = verbs.firstIndex(of: "shutdown")
    let erase = verbs.firstIndex(of: "erase")
    XCTAssertNotNil(shutdown)
    XCTAssertNotNil(erase)
    XCTAssertLessThan(shutdown!, erase!)
  }

  func testEraseOfAShutdownSimulatorDoesNotShutDown() {
    let host = host()
    XCTAssertEqual(runCLI(["erase", udid, "--json"], host: host).status, 0)
    XCTAssertFalse(subcommands(host).contains("shutdown"))
    XCTAssertTrue(subcommands(host).contains("erase"))
  }

  func testNothingIsErasedOrDeletedWhenTheShutdownFails() {
    for command in ["erase", "delete"] {
      let host = host(state: "Booted")
      host.shutdownFailure = "cannot shut down"
      let r = runCLI([command, udid], host: host)
      XCTAssertEqual(r.status, 1, command)
      XCTAssertTrue(r.stderr.contains("cannot shut down"), r.stderr)
      XCTAssertFalse(subcommands(host).contains(command), "\(command) must not run")
      XCTAssertEqual(host.devices.count, 1)
    }
  }

  func testNothingIsErasedOrDeletedWhenTheDeviceNeverReachesShutdown() {
    for command in ["erase", "delete"] {
      let host = host(state: "Booted")
      host.stuckBooted = true
      // The 30s wait is real time at the CLI, so use the library with a fake clock.
      var ctl = Simctl(runner: host)
      let clock = TestClock()
      ctl.now = { clock.now }
      ctl.sleep = { clock.advance($0) }
      XCTAssertThrowsError(
        try command == "erase" ? ctl.eraseDevice(udid: udid) : ctl.deleteDevice(udid: udid)
      ) {
        XCTAssertEqual("\($0)", "timed out waiting for \(udid) to shut down")
      }
      XCTAssertFalse(subcommands(host).contains(command))
    }
  }

  func testEraseAndDeleteNeverReachAnAlias() {
    for command in ["erase", "delete"] {
      for target in ["all", "booted", "00000000-0000-0000-0000-000000000000"] {
        let host = host(state: "Booted")
        let r = runCLI([command, target], host: host)
        XCTAssertEqual(r.status, 1, "\(command) \(target)")
        XCTAssertEqual(r.stderr, "simslim: no simulator with udid \(target)\n")
        XCTAssertFalse(subcommands(host).contains("shutdown"), "\(command) \(target)")
        XCTAssertFalse(subcommands(host).contains(command), "\(command) \(target)")
      }
    }
  }

  func testDeleteRemovesTheDevice() throws {
    let host = host(state: "Booted")
    let r = runCLI(["delete", udid, "--json"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(
      try JSONDecoder().decode(SimulatorMutationOutput.self, from: Data(r.stdout.utf8)),
      SimulatorMutationOutput(action: "delete", udid: udid))
    XCTAssertEqual(host.devices.count, 0)
    XCTAssertEqual(
      runCLI(["delete", udid], host: self.host()).stdout, "Deleted simulator \(udid).\n")
  }

  func testManagementStaysInTheDevicesOwnSet() {
    for token in ["testing", "/custom/set"] {
      let extra: [String] = token == "testing" ? [] : ["--set", token]
      for command in [["rename", udid, "N"], ["erase", udid], ["delete", udid]] {
        let host = FakeHost(devices: [])
        host.sets[token] = [.init(udid: udid, name: "d", state: "Booted")]
        let r = runCLI(extra + command, host: host)
        XCTAssertEqual(r.status, 0, "\(token) \(command): \(r.stderr)")
      }
    }
  }

  func testAFailedSimctlCommandIsReportedWithItsOutput() {
    let host = host()
    host.managementFailure = "Unable to delete: in use"
    let r = runCLI(["delete", udid], host: host)
    XCTAssertEqual(r.status, 1)
    XCTAssertEqual(
      r.stderr, "simslim: xcrun simctl delete \(udid): exit status 1: Unable to delete: in use\n")
  }
}

extension ManagementCommandTests {
  func testErasingOrDeletingADeviceThatIsNotSettledIsRefused() {
    for command in ["erase", "delete"] {
      for state in ["Booting", "Shutting Down", "Creating"] {
        let host = FakeHost(devices: [.init(udid: udid, name: "d", state: state)])
        let r = runCLI([command, udid], host: host)
        XCTAssertEqual(r.status, 1, "\(command) \(state)")
        XCTAssertTrue(r.stderr.contains("wait until it is Booted or Shutdown"), r.stderr)
        XCTAssertFalse(subcommands(host).contains(command))
        XCTAssertFalse(subcommands(host).contains("shutdown"))
      }
    }
  }

  func testNamesTrimLikeGoAndDoNotTrimAZeroWidthSpace() {
    let host = host()
    XCTAssertEqual(runCLI(["rename", udid, "\u{3000}x\u{00A0}"], host: host).status, 0)
    XCTAssertEqual(host.devices[0].name, "x")
    // U+200B is not space to Go: it is a name.
    XCTAssertEqual(runCLI(["rename", udid, "\u{200B}"], host: host).status, 0)
    XCTAssertEqual(host.devices[0].name, "\u{200B}")
  }

  func testGoQuoteMatchesStrconvQuote() {
    XCTAssertEqual(goQuote("plain"), "\"plain\"")
    XCTAssertEqual(goQuote("a\"b\\c"), "\"a\\\"b\\\\c\"")
    XCTAssertEqual(goQuote("é 日本 👍"), "\"é 日本 👍\"")
    XCTAssertEqual(goQuote("a\u{200D}b"), "\"a\\u200db\"")  // zero-width joiner
    XCTAssertEqual(goQuote("A\u{00A0}B"), "\"A\\u00a0B\"")  // no-break space
    XCTAssertEqual(goQuote("x\u{2028}"), "\"x\\u2028\"")
    XCTAssertEqual(goQuote("\u{E000}"), "\"\\ue000\"")  // private use
    XCTAssertEqual(goQuote("\u{FEFF}"), "\"\\ufeff\"")
    XCTAssertEqual(goQuote("\u{E0001}"), "\"\\U000e0001\"")  // tag character, above U+FFFF
    XCTAssertEqual(goQuote("\n\t\u{07}"), "\"\\n\\t\\a\"")
    XCTAssertEqual(goQuote("👨\u{200D}👩"), "\"👨\\u200d👩\"")
  }
}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var t = Date(timeIntervalSince1970: 2_000_000)
  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return t
  }
  func advance(_ s: TimeInterval) {
    lock.lock()
    t = t.addingTimeInterval(s)
    lock.unlock()
  }
}
