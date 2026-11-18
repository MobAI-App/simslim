// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import TestSupport
import XCTest

@testable import SimSlimKit

final class DiskCleanupSimulatorTests: XCTestCase {
  func testAnInvalidSelectionIsRefusedBeforeABootedSimulatorIsShutDown() throws {
    let udid = "AAAAAAAA-0000-0000-0000-000000000001"
    let root = NSTemporaryDirectory() + "simslim-diskkit-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    try FileManager.default.createDirectory(
      atPath: "\(root)/\(udid)/data", withIntermediateDirectories: true)
    let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", state: "Booted")])
    host.dataRoot = root
    host.disabled[udid] = []
    for ids in [["nope"], ["required-siri-assets"], []] as [[String]] {
      XCTAssertThrowsError(
        try Simctl(runner: host).cleanDeviceDisk(
          udid: udid, categoryIDs: ids, preserveBootState: false), "\(ids)")
      XCTAssertFalse(
        host.calls.contains { $0.arguments.contains("shutdown") },
        "\(ids): the simulator kept running")
    }
    XCTAssertEqual(host.devices[0].state, "Booted")
  }

  func testASimulatorThatIsBootingIsNeverCleanedUnderneath() throws {
    let udid = "AAAAAAAA-0000-0000-0000-000000000001"
    let root = NSTemporaryDirectory() + "simslim-diskkit-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let cache = "\(root)/\(udid)/data/Library/Caches/c.bin"
    try FileManager.default.createDirectory(
      atPath: (cache as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(count: 4096).write(to: URL(fileURLWithPath: cache))
    for state in ["Booting", "Shutting Down"] {
      let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", state: state)])
      host.dataRoot = root
      XCTAssertThrowsError(
        try Simctl(runner: host).cleanDeviceDisk(
          udid: udid, categoryIDs: ["caches"], preserveBootState: false), state
      ) {
        XCTAssertTrue("\($0)".contains("wait until it is Booted or Shutdown"), "\($0)")
      }
      XCTAssertTrue(FileManager.default.fileExists(atPath: cache), state)
    }
  }

  func testACleanupFailureAndARebootFailureAreReportedTogether() throws {
    let udid = "AAAAAAAA-0000-0000-0000-000000000001"
    let root = NSTemporaryDirectory() + "simslim-diskkit-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: root) }
    let data = "\(root)/\(udid)/data"
    try FileManager.default.createDirectory(
      atPath: data + "/Media/log", withIntermediateDirectories: true)
    // An in-tree symlink makes the cleanup itself fail.
    try FileManager.default.createSymbolicLink(
      atPath: data + "/var", withDestinationPath: data + "/Media")
    let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", state: "Booted")])
    host.dataRoot = root
    host.disabled[udid] = []
    host.bootFailure = "boot refused"
    XCTAssertThrowsError(
      try Simctl(runner: host).cleanDeviceDisk(
        udid: udid, categoryIDs: ["logs"], preserveBootState: true)
    ) {
      let text = "\($0)"
      XCTAssertTrue(text.contains("refusing symlinked cleanup path"), text)
      XCTAssertTrue(text.contains("; additionally could not restore boot state: "), text)
      XCTAssertTrue(text.contains("boot refused"), text)
    }
  }
}
