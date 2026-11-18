import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class TopCommandTests: XCTestCase {
  func testTooManyArguments() {
    let r = runCLI(["top", "a", "b"], host: standardHost())
    XCTAssertEqual(r.status, 1)
    XCTAssertEqual(r.stderr, "simslim: top takes at most one simulator UDID\n")
  }

  func testPipedOutputIsAOneShotFleetTable() {
    let r = runCLI(["top"], host: standardHost())
    XCTAssertEqual(r.status, 0, r.stderr)
    let lines = r.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(
      lines[0], "SIMULATOR                      OS             STATE   PROC    CPU      RAM")
    // The 1 GB iOS 18.4 simulator comes first, as the largest.
    XCTAssertTrue(lines[1].hasPrefix("iPhone 16 · 33333333"), lines[1])
    XCTAssertTrue(lines[1].contains("iOS 18.4"))
    XCTAssertTrue(lines[1].contains("stock"))
    XCTAssertTrue(lines[2].hasPrefix("iPhone 17 · 11111111"), lines[2])
    XCTAssertTrue(lines[2].contains("part"))
    XCTAssertEqual(lines[3], "2 booted · total 1.0G")
    XCTAssertFalse(r.stdout.contains("\u{1B}"), "no terminal codes in a pipe")
  }

  func testPipedDrillDownListsProcessesBiggestFirst() {
    let r = runCLI(["top", bootedUDID], host: standardHost())
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(
      r.stdout,
      """
      iPhone 17 — daemons by RAM
           RAM    CPU  COMMAND
         20.0M   2.0%  SpringBoard
         10.0M   1.0%  launchd_sim

      """)
  }

  func testJSONFleetCarriesDiskAndMemory() throws {
    let host = standardHost()
    host.dataRoot = NSTemporaryDirectory() + "simslim-top-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: host.dataRoot!) }
    for udid in [bootedUDID, oldUDID] {
      try FileManager.default.createDirectory(
        atPath: "\(host.dataRoot!)/\(udid)/data", withIntermediateDirectories: true)
      host.duKiB["\(host.dataRoot!)/\(udid)"] = 2048
    }
    let r = runCLI(["top", "--json"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    let out = try JSONDecoder().decode(TopOutput.self, from: Data(r.stdout.utf8))
    XCTAssertEqual(out.sims.map(\.device.name), ["iPhone 16", "iPhone 17"])
    XCTAssertEqual(out.sims.map(\.diskBytes), [2_097_152, 2_097_152])
    XCTAssertEqual(out.sims[1].managedDisabled, 100)
    XCTAssertEqual(out.sims[1].managedTotal, 173)
    XCTAssertEqual(out.sims[1].memory, MemoryMeasurement(processes: 2, bytes: 30 << 20, cpu: 3))
    XCTAssertEqual(out.totalBytes, (30 << 20) + (1 << 30))
    // The keys the Go output uses, flattened with the device's.
    XCTAssertTrue(r.stdout.contains("\"diskBytes\""))
    XCTAssertTrue(r.stdout.contains("\"platform\" : \"iOS\""))
  }

  func testJSONDrillDownTotalsTheProcesses() throws {
    let r = runCLI(["top", "--json", bootedUDID], host: standardHost())
    XCTAssertEqual(r.status, 0, r.stderr)
    let out = try JSONDecoder().decode(TopProcesses.self, from: Data(r.stdout.utf8))
    XCTAssertEqual(out.udid, bootedUDID)
    XCTAssertEqual(out.name, "iPhone 17")
    XCTAssertEqual(out.processes.map(\.command), ["SpringBoard", "launchd_sim"])
    XCTAssertEqual(out.totalBytes, 30 << 20)
  }

  func testDrillDownOfAShutdownSimulatorIsAnError() {
    let r = runCLI(["top", shutdownUDID], host: standardHost())
    XCTAssertEqual(r.status, 1)
    XCTAssertEqual(
      r.stderr, "simslim: simulator \(shutdownUDID) does not appear to be booted\n")
  }

  func testNoBootedSimulators() {
    let host = FakeHost(devices: [.init(udid: shutdownUDID, name: "iPad", state: "Shutdown")])
    let r = runCLI(["top"], host: host)
    XCTAssertEqual(r.status, 0)
    XCTAssertTrue(r.stdout.hasSuffix("0 booted · total 0B\n"), r.stdout)
  }

  func testASimulatorWhoseStatusCannotBeReadStillAppears() throws {
    let host = standardHost()
    host.disabled[bootedUDID] = nil  // print-disabled fails for it
    let r = runCLI(["top", "--json"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    let out = try JSONDecoder().decode(TopOutput.self, from: Data(r.stdout.utf8))
    let sim = try XCTUnwrap(out.sims.first { $0.device.udid == bootedUDID })
    XCTAssertNil(sim.managedDisabled)
    XCTAssertFalse(sim.statusError.isEmpty)
    XCTAssertNotNil(sim.memory)
  }

  // MARK: - disk

  func testDiskUsageResolvesTheUDIDAndMeasuresItsDeviceDirectory() throws {
    let host = standardHost()
    host.dataRoot = NSTemporaryDirectory() + "simslim-du-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: host.dataRoot!) }
    try FileManager.default.createDirectory(
      atPath: "\(host.dataRoot!)/\(bootedUDID)/data", withIntermediateDirectories: true)
    host.duKiB["\(host.dataRoot!)/\(bootedUDID)"] = 5
    let ctl = Simctl(runner: host)
    XCTAssertEqual(try ctl.deviceDiskUsage(udid: bootedUDID), 5120)
    // An alias never becomes a filesystem path.
    XCTAssertThrowsError(try ctl.deviceDiskUsage(udid: "all"))
    XCTAssertFalse(host.calls.contains { $0.executable == .du && $0.arguments.contains("all") })
  }

  func testDiskUsageRefusesASymlinkedOrMissingDataDirectory() throws {
    let host = standardHost()
    let root = NSTemporaryDirectory() + "simslim-du-\(UUID().uuidString)"
    host.dataRoot = root
    defer { try? FileManager.default.removeItem(atPath: root) }
    let ctl = Simctl(runner: host)
    XCTAssertThrowsError(try ctl.deviceDiskUsage(udid: bootedUDID)) {
      XCTAssertTrue("\($0)".hasPrefix("locate simulator data: "), "\($0)")
    }
    try FileManager.default.createDirectory(
      atPath: "\(root)/\(bootedUDID)", withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      atPath: root + "/elsewhere", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: "\(root)/\(bootedUDID)/data", withDestinationPath: root + "/elsewhere")
    XCTAssertThrowsError(try ctl.deviceDiskUsage(udid: bootedUDID)) {
      XCTAssertTrue("\($0)".hasPrefix("simulator data path is not a real directory: "), "\($0)")
    }
    XCTAssertFalse(host.calls.contains { $0.executable == .du })
  }

  func testEqualFootprintsOrderByPID() throws {
    let host = standardHost()
    host.psOutput = """
        PID  PPID  %CPU COMM
        200     1   1.0 /x/launchd_sim
        205   200   2.0 /x/zeta
        203   200   2.0 /x/alpha
        204   200   2.0 /x/mid
      """
    host.topOutput = "PID    MEM\n200    10M\n203    5M\n204    5M\n205    5M\n"
    let procs = try Simctl(runner: host).measureProcesses(udid: bootedUDID)
    XCTAssertEqual(procs.map(\.pid), [200, 203, 204, 205])
  }

  func testNoDataPathIsAnError() {
    let host = standardHost()
    host.emptyDataPath = true
    XCTAssertThrowsError(try Simctl(runner: host).deviceDiskUsage(udid: bootedUDID)) {
      XCTAssertEqual("\($0)", "simctl reported no data path for \(bootedUDID)")
    }
    XCTAssertFalse(host.calls.contains { $0.executable == .du })
  }

  // MARK: - the terminal screen

  func testTheLiveScreenIsOnlyDrawnForARealTerminal() {
    // With stdin/stdout not a terminal the command prints once and exits.
    let r = runCLI(["top"], host: standardHost())
    XCTAssertFalse(r.stdout.contains("\u{1B}[?1049h"))
  }
}
