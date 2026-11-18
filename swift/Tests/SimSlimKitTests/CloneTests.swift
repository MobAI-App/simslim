import Foundation
import TestSupport
import XCTest

@testable import SimSlimKit

/// A clock that only moves when the code under test sleeps.
private final class Clock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_000_000)
  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }
  func advance(_ seconds: TimeInterval) {
    lock.lock()
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }
}

private final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false
  private var counter = 0
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
  func bump() -> Int {
    lock.lock()
    defer { lock.unlock() }
    counter += 1
    return counter
  }
}

final class CloneTests: XCTestCase {
  private let src = "AAAAAAAA-0000-0000-0000-000000000001"
  private let dst = "BBBBBBBB-0000-0000-0000-000000000002"
  private var root = ""
  private let fm = FileManager.default
  private var label: String { Catalog.categories[0].labels[0] }
  private let unmanaged = "com.example.not-simslim"

  override func setUpWithError() throws {
    root = try resolvedPath(NSTemporaryDirectory()) + "/simslim-clone-\(UUID().uuidString)"
    try fm.createDirectory(atPath: root + "/store", withIntermediateDirectories: true)
  }

  override func tearDown() { try? fm.removeItem(atPath: root) }

  private var home: String { root + "/home" }
  private func data(_ udid: String) -> String { "\(root)/devices/\(udid)/data" }

  private func write(_ path: String, _ text: String = "x") throws {
    try fm.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  /// A host with a source simulator (and, for repair, the clone as well).
  private func host(
    source: String = "Shutdown", clone: String? = nil,
    cloneRuntime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  ) throws -> FakeHost {
    var devices: [FakeHost.FakeDevice] = [.init(udid: src, name: "Source", state: source)]
    try write(data(src) + "/Media/photo.jpg", "photo")
    if let clone {
      devices.append(.init(udid: dst, name: "Old clone", runtime: cloneRuntime, state: clone))
      try fm.createDirectory(atPath: data(dst), withIntermediateDirectories: true)
    }
    let host = FakeHost(devices: devices)
    host.dataRoot = root + "/devices"
    host.storeRoot = root + "/store"
    host.disabled[src] = [label, unmanaged]
    host.cloneUDIDs = [dst]
    host.psOutput = "10 /usr/bin/launchd_sim SIMULATOR_UDID=\(dst)\n"
    return host
  }

  private func simctl(_ host: FakeHost) -> Simctl {
    var simctl = Simctl(runner: host)
    simctl.retryDelays = [0, 0, 0, 0]
    let clock = Clock()
    simctl.now = { clock.now }
    simctl.sleep = { clock.advance($0) }
    simctl.storeRoot = root + "/store"
    return simctl
  }

  private func clone(_ host: FakeHost, name: String = "Clone") throws -> String {
    try simctl(host).cloneDevice(udid: src, name: name, home: home, restoreTimeout: 60)
  }

  private func repair(_ host: FakeHost) throws {
    try simctl(host).repairClonedDevice(
      sourceUDID: src, cloneUDID: dst, home: home, restoreTimeout: 60)
  }

  private func state(_ host: FakeHost, _ udid: String) -> String? {
    host.devices.first { $0.udid == udid }?.state
  }

  private func verbs(_ host: FakeHost) -> [String] {
    host.calls.compactMap { call -> String? in
      guard call.executable == .xcrun else { return nil }
      var args = call.arguments
      if args.count > 2, args[1] == "--set" { args.removeSubrange(1...2) }
      guard args.count > 2, ["boot", "shutdown", "clone", "delete"].contains(args[1]) else {
        return nil
      }
      return args[1] + ":" + (args[2] == src ? "src" : args[2] == dst ? "dst" : args[2])
    }
  }

  private func failure(_ body: () throws -> Void) -> String {
    do {
      try body()
      return ""
    } catch { return "\(error)" }
  }

  // MARK: - clone

  func testACloneOfAShutDownSourceLeavesBothShutDown() throws {
    let host = try host()
    XCTAssertEqual(try clone(host, name: "  My Clone "), dst)
    XCTAssertEqual(state(host, src), "Shutdown")
    XCTAssertEqual(state(host, dst), "Shutdown")
    XCTAssertEqual(host.devices.first { $0.udid == dst }?.name, "My Clone")
  }

  func testACloneOfABootedSourceBringsTheSourceBack() throws {
    let host = try host(source: "Booted")
    XCTAssertEqual(try clone(host), dst)
    XCTAssertEqual(state(host, src), "Booted")
    XCTAssertEqual(state(host, dst), "Shutdown")
  }

  func testTheSourceIsShutDownBeforeTheCopyAndTheCloneBeforeItIsReturned() throws {
    let host = try host(source: "Booted")
    _ = try clone(host)
    let order = verbs(host)
    let copy = try XCTUnwrap(order.firstIndex(of: "clone:src"))
    XCTAssertTrue(order[..<copy].contains("shutdown:src"), "\(order)")
    XCTAssertEqual(order.last, "boot:src", "the source is restored last: \(order)")
    let cloneShutdown = try XCTUnwrap(order.lastIndex(of: "shutdown:dst"))
    XCTAssertGreaterThan(cloneShutdown, copy)
  }

  func testOnlySlimmableOverridesAreAppliedToTheClone() throws {
    let host = try host()
    _ = try clone(host)
    let disabled = try XCTUnwrap(host.disabled[dst])
    XCTAssertTrue(disabled.contains(label))
    XCTAssertFalse(disabled.contains(unmanaged), "an unrelated override is not copied")
  }

  func testTheClonedFilesAreTheSourcesAndNotLinkedToIt() throws {
    let host = try host()
    _ = try clone(host)
    XCTAssertEqual(
      try String(contentsOfFile: data(dst) + "/Media/photo.jpg", encoding: .utf8), "photo")
  }

  func testAnInvalidNameIsRefusedBeforeAnyCommand() throws {
    let host = try host()
    for name in ["", "   ", "bad\u{07}name", String(repeating: "x", count: 129)] {
      XCTAssertNotEqual(failure { _ = try self.clone(host, name: name) }, "", name)
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testASourceInTransitionIsRefused() throws {
    for state in ["Booting", "Shutting Down", "Creating"] {
      let host = try host(source: state)
      XCTAssertEqual(
        failure { _ = try self.clone(host) },
        "simulator must be booted or shutdown before cloning (it is \(state))")
      XCTAssertEqual(verbs(host), [], state)
    }
  }

  func testAnUnknownSourceFails() throws {
    let host = try host()
    let text = failure {
      _ = try self.simctl(host).cloneDevice(
        udid: "NOPE", name: "x", home: self.home, restoreTimeout: 60)
    }
    XCTAssertEqual(text, "no simulator with udid NOPE")
  }

  func testASourceWithNoDataDirectoryFails() throws {
    let host = try host()
    try fm.removeItem(atPath: data(src))
    XCTAssertTrue(failure { _ = try self.clone(host) }.contains("locate simulator data"))
    XCTAssertEqual(verbs(host), [])
  }

  func testAFailedCopyStillRestoresTheSource() throws {
    let host = try host(source: "Booted")
    host.cloneFailure = "disk full"
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(text.contains("disk full"), text)
    XCTAssertEqual(state(host, src), "Booted")
    XCTAssertEqual(host.devices.count, 1)
  }

  func testAMalformedUDIDFromSimctlFailsAndTheSourceIsRestored() throws {
    let host = try host(source: "Booted")
    host.cloneOutput = "something odd\n"
    XCTAssertTrue(failure { _ = try self.clone(host) }.contains("invalid UDID"))
    XCTAssertEqual(state(host, src), "Booted")
  }

  func testACloneThatStillPointsAtTheSourceIsDeleted() throws {
    let host = try host(source: "Booted")
    try fm.createSymbolicLink(
      atPath: data(src) + "/bad", withDestinationPath: "/elsewhere/\(src)/f")
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(text.hasPrefix("prepare cloned simulator \(dst): "), text)
    XCTAssertTrue(text.hasSuffix("; deleted the unsafe clone"), text)
    XCTAssertNil(state(host, dst), "the unsafe clone is gone")
    XCTAssertEqual(state(host, src), "Booted")
  }

  func testAFailureToDeleteTheUnsafeCloneIsReported() throws {
    let host = try host()
    try fm.createSymbolicLink(
      atPath: data(src) + "/bad", withDestinationPath: "/elsewhere/\(src)/f")
    host.managementFailure = "delete refused"
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(text.contains("; additionally could not delete the unsafe clone: "), text)
    XCTAssertTrue(text.contains("delete refused"), text)
    XCTAssertNotNil(state(host, dst))
  }

  func testACloneHoldingASourcePathOpenIsDeleted() throws {
    let host = try host()
    let leaked = "\(root)/devices/\(src)/data/Library/x"
    host.lsofResult = { pids in
      CommandResult(status: 0, stdout: Data("p\(pids[0])\nn\(leaked)\n".utf8))
    }
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(
      text.contains("clone process 10 still has a source simulator path open: \(leaked)"), text)
    XCTAssertNil(state(host, dst))
  }

  func testAnAuditThatNeverSeesTheCloneRunningRetriesThenDeletesIt() throws {
    let host = try host()
    host.psOutput = ""
    let pings = Flag()
    host.onCall = { exe, _ in if exe == .ps { _ = pings.bump() } }
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(
      text.contains("could not identify any running processes for cloned simulator \(dst)"), text)
    XCTAssertEqual(pings.bump() - 1, 3, "three attempts")
    XCTAssertNil(state(host, dst))
  }

  func testAnAuditThatSeesTheCloneOnTheSecondTryPasses() throws {
    let host = try host()
    let marker = host.psOutput
    host.psOutput = ""
    let count = Flag()
    nonisolated(unsafe) let fake = host
    host.onCall = { exe, _ in
      if exe == .ps, count.bump() == 2 { fake.psOutput = marker }
    }
    XCTAssertEqual(try clone(host), dst)
  }

  func testAFailureToRestoreTheSourceIsReportedWithTheNewClone() throws {
    let host = try host(source: "Booted")
    nonisolated(unsafe) let fake = host
    let dstID = dst
    host.onCall = { exe, args in
      if exe == .xcrun, args.contains("shutdown"), args.contains(dstID) {
        fake.bootFailure = "boom"
      }
    }
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(
      text.hasPrefix("cloned simulator \(dst), but could not restore the source boot state: "), text
    )
    XCTAssertNotNil(state(host, dst), "a good clone is kept")
  }

  func testAFailureAndAFailedRestoreAreBothReported() throws {
    let host = try host(source: "Booted")
    host.cloneFailure = "disk full"
    nonisolated(unsafe) let fake = host
    host.onCall = { exe, args in
      if exe == .xcrun, args.contains("clone") { fake.bootFailure = "boom" }
    }
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(text.contains("disk full"), text)
    XCTAssertTrue(text.contains("; additionally could not restore the source boot state: "), text)
    XCTAssertTrue(text.contains("boom"), text)
  }

  func testCancellingStillDeletesTheUnsafeCloneAndRestoresTheSource() throws {
    let host = try host(source: "Booted")
    let cancelled = Flag()
    let dstID = dst
    host.onCall = { exe, args in
      if exe == .xcrun, args.contains("clone"), !args.contains(dstID) { cancelled.set() }
    }
    var handle = simctl(host)
    handle.cancelled = { cancelled.isSet }
    let text = failure {
      _ = try handle.cloneDevice(udid: self.src, name: "x", home: self.home, restoreTimeout: 60)
    }
    XCTAssertTrue(text.contains("context canceled"), text)
    XCTAssertTrue(text.hasSuffix("; deleted the unsafe clone"), text)
    XCTAssertNil(state(host, dst))
    XCTAssertEqual(state(host, src), "Booted", "cleanup is not itself cancelled")
  }

  // MARK: - repair

  func testRepairRebasesALegacyCloneAndLeavesItShutDown() throws {
    let host = try host(source: "Shutdown", clone: "Shutdown")
    try fm.createSymbolicLink(
      atPath: data(dst) + "/Logs", withDestinationPath: "\(root)/devices/\(src)/data/Media")
    try write(data(dst) + "/Library/p.plist", "<s>\(src)</s>")
    host.disabled[dst] = [label]
    try repair(host)
    XCTAssertEqual(
      try fm.destinationOfSymbolicLink(atPath: data(dst) + "/Logs"), data(dst) + "/Media")
    XCTAssertEqual(
      try String(contentsOfFile: data(dst) + "/Library/p.plist", encoding: .utf8), "<s>\(dst)</s>")
    XCTAssertEqual(state(host, dst), "Shutdown")
    XCTAssertEqual(state(host, src), "Shutdown")
    XCTAssertTrue(host.disabled[dst]?.contains(label) == true, "its service profile is kept")
  }

  func testRepairKeepsBothBootedSimulatorsBooted() throws {
    let host = try host(source: "Booted", clone: "Booted")
    host.disabled[dst] = [label, unmanaged]
    try repair(host)
    XCTAssertEqual(state(host, src), "Booted")
    XCTAssertEqual(state(host, dst), "Booted")
    XCTAssertEqual(verbs(host).filter { $0 == "shutdown:src" }.count, 1)
  }

  func testRepairShutsBothDownBeforeRebuildingAnything() throws {
    let host = try host(source: "Booted", clone: "Booted")
    host.disabled[dst] = [label]
    try repair(host)
    let order = verbs(host)
    XCTAssertEqual(order.prefix(2), ["shutdown:dst", "shutdown:src"], "\(order)")
    XCTAssertEqual(order.last, "boot:src")
  }

  func testRepairRefusesWhatItCannotTrust() throws {
    let host = try host(source: "Shutdown", clone: "Shutdown")
    XCTAssertEqual(
      failure {
        try self.simctl(host).repairClonedDevice(
          sourceUDID: self.src, cloneUDID: self.src, home: self.home, restoreTimeout: 60)
      },
      "clone source and destination UDIDs must be distinct")
    XCTAssertEqual(verbs(host), [])

    let other = try self.host(
      source: "Shutdown", clone: "Shutdown",
      cloneRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-18-4")
    XCTAssertEqual(
      failure { try self.repair(other) }, "source and clone runtimes differ (iOS 27.2 and iOS 18.4)"
    )
    let tv = try self.host(
      source: "Shutdown", clone: "Shutdown",
      cloneRuntime: "com.apple.CoreSimulator.SimRuntime.tvOS-27-2")
    XCTAssertTrue(failure { try self.repair(tv) }.contains("runtimes differ"))

    for (s, c) in [("Booting", "Shutdown"), ("Shutdown", "Shutting Down")] {
      let busy = try self.host(source: s, clone: c)
      let bad = s == "Booting" ? src : dst
      let current = s == "Booting" ? s : c
      XCTAssertEqual(
        failure { try self.repair(busy) },
        "simulator \(bad) must be booted or shutdown before repair (it is \(current))")
      XCTAssertEqual(verbs(busy), [])
    }
    XCTAssertEqual(
      try String(contentsOfFile: data(src) + "/Media/photo.jpg", encoding: .utf8), "photo")
  }

  func testRepairRefusesACloneInAnotherDeviceSet() throws {
    let host = try host(source: "Shutdown", clone: nil)
    host.sets["testing"] = [.init(udid: dst, name: "Elsewhere")]
    try fm.createDirectory(atPath: data(dst), withIntermediateDirectories: true)
    XCTAssertEqual(
      failure { try self.repair(host) }, "source and clone must belong to the same simulator set")
    XCTAssertEqual(verbs(host), [])
  }

  func testAFailedRepairLeavesTheCloneShutDownAndTheSourceRestored() throws {
    let host = try host(source: "Booted", clone: "Booted")
    host.disabled[dst] = [label]
    try fm.createSymbolicLink(
      atPath: data(dst) + "/bad", withDestinationPath: "/elsewhere/\(src)/f")
    let text = failure { try self.repair(host) }
    XCTAssertTrue(text.contains("still resolves into the source simulator"), text)
    XCTAssertEqual(state(host, dst), "Shutdown", "left safely shut down")
    XCTAssertEqual(state(host, src), "Booted")
    XCTAssertNotNil(state(host, dst), "a repair never deletes the clone")
  }

  func testARepairWhoseAuditFindsAnOpenSourceFileFailsSafely() throws {
    let host = try host(source: "Shutdown", clone: "Booted")
    host.disabled[dst] = [label]
    host.psOutput = "10 /x SIMULATOR_UDID=\(dst)\n"
    let leaked = "\(root)/devices/\(src)/data/f"
    host.lsofResult = { pids in
      CommandResult(status: 0, stdout: Data("p\(pids[0])\nn\(leaked)\n".utf8))
    }
    let text = failure { try self.repair(host) }
    XCTAssertTrue(text.contains("still has a source simulator path open"), text)
    XCTAssertEqual(state(host, dst), "Shutdown")
  }

  func testAFailedRepairThatCannotShutTheCloneDownSaysSo() throws {
    let host = try host(source: "Shutdown", clone: "Shutdown")
    host.disabled[dst] = [label]
    let leaked = "\(root)/devices/\(src)/data/f"
    host.lsofResult = { pids in
      CommandResult(status: 0, stdout: Data("p\(pids[0])\nn\(leaked)\n".utf8))
    }
    nonisolated(unsafe) let fake = host
    host.onCall = { exe, args in
      if exe == .xcrun, args.contains("bootstatus") { fake.stuckBooted = true }
    }
    let text = failure { try self.repair(host) }
    XCTAssertTrue(text.contains("still has a source simulator path open"), text)
    XCTAssertTrue(text.contains("; additionally could not leave the clone safely shutdown: "), text)
  }

  func testRepairOnlyTouchesTheCloneNeverTheSource() throws {
    let host = try host(source: "Shutdown", clone: "Shutdown")
    try write(data(src) + "/Library/p.plist", "<s>\(src)</s>")
    try fm.createSymbolicLink(atPath: data(src) + "/l", withDestinationPath: data(src) + "/Media")
    host.disabled[dst] = []
    try repair(host)
    XCTAssertEqual(
      try String(contentsOfFile: data(src) + "/Library/p.plist", encoding: .utf8), "<s>\(src)</s>")
    XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: data(src) + "/l"), data(src) + "/Media")
  }

  // MARK: - review follow-ups

  func testACloneUDIDThatNamesTheSourceOrAnyExistingSimulatorDeletesNothing() throws {
    for output in [src, src.lowercased(), "CCCCCCCC-0000-0000-0000-000000000003"] {
      let host = try host(source: "Booted")
      host.devices.append(.init(udid: "CCCCCCCC-0000-0000-0000-000000000003", name: "Bystander"))
      host.cloneOutput = output + "\n"
      let text = failure { _ = try self.clone(host) }
      XCTAssertTrue(
        text.contains("returned the UDID of an existing simulator"), "\(output): \(text)")
      XCTAssertFalse(verbs(host).contains { $0.hasPrefix("delete:") }, "\(output): \(verbs(host))")
      XCTAssertNotNil(state(host, src), "the source survives")
      XCTAssertNotNil(state(host, "CCCCCCCC-0000-0000-0000-000000000003"))
      XCTAssertEqual(state(host, src), "Booted")
    }
  }

  func testACloneCreatedInAnotherSetIsReported() throws {
    let host = try host()
    host.cloneIntoSet = "testing"
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(
      text.contains("CoreSimulator placed clone \(dst) in testing instead of source set default"),
      text)
  }

  func testCleanupStillRunsAfterTheOperationBudgetIsSpent() throws {
    let host = try host(source: "Booted")
    let clock = Clock()
    var handle = simctl(host)
    handle.now = { clock.now }
    handle.sleep = { clock.advance($0) }
    handle.deadline = clock.now.addingTimeInterval(100)
    let dstID = dst
    host.onCall = { exe, args in
      if exe == .xcrun, args.contains("bootstatus"), args.contains(dstID) { clock.advance(1000) }
    }
    let text = failure {
      _ = try handle.cloneDevice(udid: self.src, name: "x", home: self.home, restoreTimeout: 60)
    }
    XCTAssertTrue(text.contains("context deadline exceeded"), text)
    XCTAssertTrue(text.hasSuffix("; deleted the unsafe clone"), text)
    XCTAssertNil(state(host, dst))
    XCTAssertEqual(state(host, src), "Booted", "the restore ran on a fresh budget")
  }

  func testTheAuditStopsWhenTheBudgetRunsOutBetweenAttempts() throws {
    let host = try host()
    host.psOutput = ""
    let clock = Clock()
    var handle = simctl(host)
    handle.now = { clock.now }
    handle.sleep = { clock.advance($0) }
    handle.deadline = clock.now.addingTimeInterval(1000)
    host.onCall = { exe, _ in if exe == .ps { clock.advance(2000) } }
    let text = failure {
      _ = try handle.cloneDevice(udid: self.src, name: "x", home: self.home, restoreTimeout: 60)
    }
    XCTAssertTrue(
      text.contains("audit cloned simulator open files: context deadline exceeded"), text)
  }

  func testAnLsofThatTimesOutIsRetriedAndThenReported() throws {
    let host = try host()
    host.lsofResult = { _ in CommandResult(status: -9, timedOut: true) }
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(text.contains("audit cloned simulator open files: signal: killed"), text)
    XCTAssertNil(state(host, dst))
  }

  func testRepairNeverFollowsALinkIntoTheSourceToRewriteItsPropertyLists() throws {
    let host = try host(source: "Shutdown", clone: "Shutdown")
    host.disabled[dst] = []
    try write(data(src) + "/Library/Preferences/a.plist", "<s>\(src)</s>")
    try write(data(src) + "/dirwithplist/b.plist", "<s>\(src)</s>")
    try write(data(src) + "/lone.plist", "<s>\(src)</s>")
    // A link to a source directory, and a .plist that is itself a link to a source file.
    try fm.createSymbolicLink(
      atPath: data(dst) + "/linkdir", withDestinationPath: data(src) + "/dirwithplist")
    try fm.createSymbolicLink(
      atPath: data(dst) + "/link.plist", withDestinationPath: data(src) + "/lone.plist")
    try repair(host)
    for path in ["/Library/Preferences/a.plist", "/dirwithplist/b.plist", "/lone.plist"] {
      XCTAssertEqual(
        try String(contentsOfFile: data(src) + path, encoding: .utf8), "<s>\(src)</s>", path)
    }
    XCTAssertEqual(
      try fm.destinationOfSymbolicLink(atPath: data(dst) + "/linkdir"), data(dst) + "/dirwithplist")
    XCTAssertEqual(
      try fm.destinationOfSymbolicLink(atPath: data(dst) + "/link.plist"), data(dst) + "/lone.plist"
    )
  }

  func testALinkThatAppearsWhileTheCloneRunsIsCaughtByTheFinalCheck() throws {
    let host = try host()
    let link = data(dst) + "/appeared-at-boot"
    let source = src
    let dstID = dst
    host.onCall = { exe, args in
      // The clone's own daemons create it after the first check, before shutdown.
      if exe == .xcrun, args.contains("shutdown"), args.contains(dstID) {
        try? FileManager.default.createSymbolicLink(
          atPath: link, withDestinationPath: "/elsewhere/\(source)/f")
      }
    }
    let text = failure { _ = try self.clone(host) }
    XCTAssertTrue(text.contains("still resolves into the source simulator"), text)
    XCTAssertTrue(text.hasSuffix("; deleted the unsafe clone"), text)
    XCTAssertNil(state(host, dst))
  }
}
