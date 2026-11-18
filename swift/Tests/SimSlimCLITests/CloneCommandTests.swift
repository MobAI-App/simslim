// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class CloneCommandTests: XCTestCase {
  private let src = "AAAAAAAA-0000-0000-0000-000000000001"
  private let dst = "BBBBBBBB-0000-0000-0000-000000000002"
  private var root = ""
  private let fm = FileManager.default

  override func setUpWithError() throws {
    root =
      try {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(NSTemporaryDirectory(), &buffer) != nil else {
          throw CocoaError(.fileNoSuchFile)
        }
        return String(cString: buffer)
      }() + "/simslim-clonecli-\(UUID().uuidString)"
    try fm.createDirectory(atPath: root + "/store", withIntermediateDirectories: true)
    try fm.createDirectory(atPath: "\(root)/devices/\(src)/data", withIntermediateDirectories: true)
  }

  override func tearDown() { try? fm.removeItem(atPath: root) }

  private func host(clone: Bool = false) throws -> FakeHost {
    var devices: [FakeHost.FakeDevice] = [.init(udid: src, name: "Source")]
    if clone {
      devices.append(.init(udid: dst, name: "Legacy"))
      try fm.createDirectory(
        atPath: "\(root)/devices/\(dst)/data", withIntermediateDirectories: true)
    }
    let host = FakeHost(devices: devices)
    host.dataRoot = root + "/devices"
    host.storeRoot = root + "/store"
    host.disabled[src] = []
    host.cloneUDIDs = [dst]
    host.psOutput = "10 /x SIMULATOR_UDID=\(dst)\n"
    return host
  }

  private func run(_ args: [String], _ host: FakeHost) -> CLIResult {
    runCLI(args, host: host, storeRoot: root + "/store", home: root + "/home")
  }

  func testCloneArgumentCountIsChecked() throws {
    let host = try host()
    for args in [["clone"], ["clone", src], ["clone", src, "a", "b"]] {
      let r = run(args, host)
      XCTAssertEqual(r.status, 1)
      XCTAssertEqual(r.stderr, "simslim: clone expects a simulator UDID and a new name\n")
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testRepairArgumentCountIsChecked() throws {
    let host = try host(clone: true)
    for args in [["repair-clone"], ["repair-clone", src], ["repair-clone", src, dst, "x"]] {
      let r = run(args, host)
      XCTAssertEqual(r.status, 1)
      XCTAssertEqual(
        r.stderr, "simslim: repair-clone expects the source UDID and cloned simulator UDID\n")
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testAnInvalidNameFailsBeforeAnyCommand() throws {
    let host = try host()
    let r = run(["clone", src, "  "], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertEqual(r.stderr, "simslim: simulator name cannot be empty\n")
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testCloneReportsTheNewSimulatorAndProgress() throws {
    let host = try host()
    let r = run(["clone", src, " Fast \"Phone\" "], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Cloned \(src) as \"Fast \\\"Phone\\\"\" (\(dst)).\n")
    XCTAssertTrue(r.stderr.contains("Cloning \(src)..."), r.stderr)
    XCTAssertEqual(host.devices.first { $0.udid == dst }?.name, "Fast \"Phone\"")
  }

  func testCloneJSONIsCleanAndMatchesTheContract() throws {
    let host = try host()
    let r = run(["clone", src, "Fast", "--json"], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stderr, "", "no progress chatter under --json")
    let object = try JSONSerialization.jsonObject(with: Data(r.stdout.utf8)) as? [String: String]
    XCTAssertEqual(object, ["action": "clone", "udid": dst, "name": "Fast", "sourceUdid": src])
  }

  func testRepairReportsAndPrintsJSON() throws {
    let host = try host(clone: true)
    host.disabled[dst] = []
    let r = run(["repair-clone", src, dst], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(
      r.stdout,
      "Repaired clone \(dst) and verified no links or open files into specified source \(src).\n")

    let json = run(["repair-clone", src, dst, "--json"], try self.host(clone: true))
    XCTAssertEqual(json.status, 0, json.stderr)
    XCTAssertEqual(json.stderr, "")
    let object = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [String: String]
    XCTAssertEqual(object, ["action": "repair-clone", "udid": dst, "sourceUdid": src])
  }

  func testAFailedCloneExitsOneWithTheMessage() throws {
    let host = try host()
    host.cloneFailure = "no space"
    let r = run(["clone", src, "x"], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("simslim: xcrun simctl clone"), r.stderr)
    XCTAssertTrue(r.stderr.contains("no space"))
    XCTAssertEqual(r.stdout, "")
  }

  func testAFailedRepairExitsOneAndPrintsNothingOnStdout() throws {
    let host = try host(clone: true)
    try fm.createSymbolicLink(
      atPath: "\(root)/devices/\(dst)/data/bad", withDestinationPath: "/elsewhere/\(src)/f")
    host.disabled[dst] = []
    let r = run(["repair-clone", src, dst], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertEqual(r.stdout, "")
    XCTAssertTrue(r.stderr.contains("still resolves into the source simulator"), r.stderr)
    let quiet = run(["repair-clone", src, dst, "--json"], host)
    XCTAssertEqual(quiet.status, 1)
    XCTAssertFalse(quiet.stderr.contains("Shutting both"), "no progress under --json")
  }
}
