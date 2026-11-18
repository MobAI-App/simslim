// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import XCTest

@testable import SimSlimKit

final class DiskUsageTests: XCTestCase {
  func testDUOutputParsing() throws {
    XCTAssertEqual(try Simctl.parseDUDiskUsage("5\t/x\n"), 5120)
    XCTAssertEqual(try Simctl.parseDUDiskUsage("0 /x"), 0)
    for bad in ["", "   \n", "abc\t/x", "-4\t/x", "99999999999999999999 /x"] {
      XCTAssertThrowsError(try Simctl.parseDUDiskUsage(bad), bad)
    }
    XCTAssertThrowsError(try Simctl.parseDUDiskUsage("\(Int64.max / 1024 + 1) /x"))
  }

  func testTopJSONKeysFollowTheGoContract() throws {
    let sim = TopSim(
      device: Device(
        udid: "U", name: "n", state: "Booted", platform: "iOS", osVersion: "27.2", set: "default"),
      managedDisabled: 3, managedTotal: 173,
      memory: MemoryMeasurement(processes: 2, bytes: 5, cpu: 1),
      diskBytes: 9)
    let data = try JSONEncoder().encode(TopOutput(sims: [sim], totalBytes: 5))
    let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    let first = (object["sims"] as! [[String: Any]])[0]
    XCTAssertEqual(
      Set(first.keys),
      [
        "udid", "name", "state", "platform", "osVersion", "set", "managedDisabled", "managedTotal",
        "memory", "diskBytes",
      ])
    XCTAssertEqual(object["totalBytes"] as? Int, 5)
    // Empty error strings and absent values are omitted, as Go's omitempty does.
    let bare = try JSONEncoder().encode(TopSim(device: Device(udid: "U"), managedTotal: 1))
    let keys = Set((try JSONSerialization.jsonObject(with: bare) as! [String: Any]).keys)
    XCTAssertFalse(keys.contains("statusError"))
    XCTAssertFalse(keys.contains("memory"))
    XCTAssertFalse(keys.contains("diskBytes"))
    let procs = try JSONEncoder().encode(TopProcesses(udid: "U", processes: [], totalBytes: 0))
    let procKeys = Set((try JSONSerialization.jsonObject(with: procs) as! [String: Any]).keys)
    XCTAssertEqual(procKeys, ["udid", "processes", "totalBytes"])
  }
}
