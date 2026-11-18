// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import TestSupport
import XCTest

@testable import SimSlimKit

private final class Lines: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [String] = []
  func add(_ line: String) {
    lock.lock()
    items.append(line)
    lock.unlock()
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return items
  }
}

final class LiveTests: XCTestCase {
  private let ios = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"
  private let watch = "com.apple.CoreSimulator.SimRuntime.watchOS-11-5"
  private let udid = "AAAAAAAA-0000-0000-0000-000000000001"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-live-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private func host(
    state: String = "Booted", runtime: String? = nil, disabled: Set<String> = [],
    loaded: Set<String> = []
  ) -> FakeHost {
    let host = FakeHost(devices: [
      .init(udid: udid, name: "iPhone", runtime: runtime ?? ios, state: state)
    ])
    host.storeRoot = root + "/store"
    if state == "Booted" {
      host.disabled[udid] = disabled
      host.loaded[udid] = loaded
    }
    return host
  }

  private func simctl(_ host: FakeHost) -> Simctl {
    var simctl = Simctl(runner: host)
    simctl.retryDelays = [0, 0, 0, 0]
    simctl.sleep = { _ in }
    return simctl
  }

  private func installPlists(
    _ host: FakeHost, labels: [String], missing: Set<String> = []
  ) throws {
    let dir = root + "/runtime/System/Library/LaunchDaemons"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    host.runtimeRoots[ios] = root + "/runtime"
    host.runtimeRoots[watch] = root + "/runtime"
    for label in labels where !missing.contains(label) {
      let path = "\(dir)/\(label).plist"
      FileManager.default.createFile(atPath: path, contents: Data())
      host.plistLabels[path] = label
    }
  }

  private func spawnVerbs(_ host: FakeHost) -> [String] {
    host.calls.compactMap { call in
      guard call.executable == .xcrun, call.arguments.count > 4, call.arguments[1] == "spawn"
      else { return nil }
      return call.arguments[4]
    }
  }

  private func category(_ id: String) -> [String] { Catalog.category(id: id)!.labels }

  private var profilePath: String { root + "/profile.json" }

  private func writeProfile(_ text: String) throws {
    try text.write(toFile: profilePath, atomically: true, encoding: .utf8)
  }

  // MARK: - enable

  func testEnableLoadsACategoryInOneBatchAndSortsTheResult() throws {
    let labels = category("search")
    let host = host(disabled: Set(labels))
    try installPlists(host, labels: labels)
    let lines = Lines()
    let out = try simctl(host).enableServices(
      udid: udid, ids: ["search"], reporter: { lines.add($0) })
    XCTAssertEqual(out.action, "enable")
    XCTAssertTrue(out.live)
    XCTAssertEqual(out.labels, labels.sorted())
    XCTAssertEqual(out.notStarted, [])
    XCTAssertEqual(host.disabled[udid], [])
    XCTAssertEqual(host.loaded[udid], Set(labels))
    XCTAssertEqual(spawnVerbs(host).filter { $0 == "load" }.count, 1)
    XCTAssertFalse(spawnVerbs(host).contains("enable"), "the batch did everything")
    XCTAssertTrue(
      lines.all.contains("  \(labels.count)/\(labels.count) services started in one batch"))
  }

  func testEnableOnlyLiftsTheOverrideOfALabelWithNoPlist() throws {
    let label = category("search")[0]
    let host = host(disabled: [label])
    try installPlists(host, labels: category("search"), missing: [label])
    let out = try simctl(host).enableServices(udid: udid, ids: [label])
    XCTAssertEqual(host.disabled[udid], [])
    XCTAssertEqual(out.labels, [label])
    XCTAssertEqual(out.notStarted, [], "launchd starts an on-demand job when asked")
    XCTAssertEqual(spawnVerbs(host).filter { $0 == "enable" }.count, 1)
    XCTAssertFalse(spawnVerbs(host).contains("bootstrap"))
  }

  func testEnableReportsALabelThatOnlyStartsAtTheNextBoot() throws {
    let labels = category("search")
    let stubborn = labels[0]
    let host = host(disabled: Set(labels))
    try installPlists(host, labels: labels)
    host.failTransition = { verb, label in
      label == stubborn && (verb == "load" || verb == "bootstrap")
        ? CommandResult(status: 1) : nil
    }
    let out = try simctl(host).enableServices(udid: udid, ids: ["search"])
    XCTAssertEqual(out.notStarted, [stubborn])
    XCTAssertFalse(host.disabled[udid]!.contains(stubborn), "its override is lifted")
    XCTAssertTrue(spawnVerbs(host).contains("bootstrap"))
  }

  func testEnableFailsWhenALabelStaysDisabled() throws {
    let label = category("search")[0]
    let host = host(disabled: [label])
    try installPlists(host, labels: [], missing: [])
    host.failTransition = { _, l in l == label ? CommandResult(status: 1) : nil }
    XCTAssertThrowsError(try simctl(host).enableServices(udid: udid, ids: [label])) {
      XCTAssertTrue(
        "\($0)".contains("still disabled") || "\($0)".contains("transitions failed"), "\($0)")
    }
  }

  func testEnableFailsWhenTheOverrideIsAcceptedButNeverLifted() throws {
    let label = category("search")[0]
    let host = host(disabled: [label])
    // launchctl exits 0 for `enable` but the override stays: only the read-back sees it.
    host.failTransition = { verb, l in
      verb == "enable" && l == label ? CommandResult(status: 0) : nil
    }
    XCTAssertThrowsError(try simctl(host).enableServices(udid: udid, ids: [label])) {
      XCTAssertEqual("\($0)", "1 of 1 services are still disabled: \(label)")
    }
  }

  func testEnableOfARunningCategoryChangesNothing() throws {
    let labels = category("search")
    let host = host(loaded: Set(labels))
    try installPlists(host, labels: labels)
    let lines = Lines()
    let out = try simctl(host).enableServices(
      udid: udid, ids: ["search"], reporter: { lines.add($0) })
    XCTAssertEqual(out.notStarted, [])
    XCTAssertTrue(lines.all.contains("  all \(labels.count) services were already running"))
    XCTAssertEqual(spawnVerbs(host).filter { !["print-disabled", "list"].contains($0) }, [])
  }

  func testEnableRejectsBadInputBeforeTouchingAnything() throws {
    let host = host()
    for (ids, fragment) in [
      (["no-such-thing"], "unknown category or managed daemon \"no-such-thing\""),
      (["com.apple.not.managed"], "unknown category or managed daemon"),
      ([], "name at least one category ID or managed daemon to enable"),
    ] {
      XCTAssertThrowsError(try simctl(host).enableServices(udid: udid, ids: ids)) {
        XCTAssertTrue("\($0)".contains(fragment), "\($0)")
      }
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testEnableNeverReachesAnAlias() throws {
    let host = host(disabled: ["com.apple.x"])
    XCTAssertThrowsError(try simctl(host).enableServices(udid: "all", ids: ["search"])) {
      XCTAssertEqual("\($0)", "no simulator with udid all")
    }
    XCTAssertTrue(spawnVerbs(host).isEmpty)
  }

  func testEnableOnAShutdownSimulatorNeedsSave() throws {
    let host = host(state: "Shutdown")
    XCTAssertThrowsError(try simctl(host).enableServices(udid: udid, ids: ["search"])) {
      let text = "\($0)"
      XCTAssertTrue(text.contains("is not booted (it is Shutdown)"), text)
      XCTAssertTrue(text.contains("pass --save <profile.json>"), text)
    }
    XCTAssertTrue(spawnVerbs(host).isEmpty)
  }

  func testEnableOnAShutdownSimulatorOnlyWritesTheProfile() throws {
    let host = host(state: "Shutdown")
    let out = try simctl(host).enableServices(udid: udid, ids: ["search"], save: profilePath)
    XCTAssertFalse(out.live)
    XCTAssertEqual(out.labels, [])
    XCTAssertEqual(out.saved, profilePath)
    XCTAssertTrue(spawnVerbs(host).isEmpty)
    XCTAssertEqual(try loadSlimProfile(path: profilePath).exceptCategories, ["search"])
  }

  // MARK: - disable

  func testDisableStopsACategoryAndReadsItBack() throws {
    let labels = category("search")
    let host = host(loaded: Set(labels))
    try installPlists(host, labels: labels)
    let out = try simctl(host).disableServices(udid: udid, ids: ["search"])
    XCTAssertEqual(out.labels, labels.sorted())
    XCTAssertEqual(out.stillEnabled, [])
    XCTAssertEqual(host.disabled[udid], Set(labels))
    XCTAssertEqual(host.loaded[udid], [])
  }

  /// What stopping `target` must keep, worked out independently: the labels it
  /// lists that some other category with every daemon enabled also lists.
  private func expectedKept(stopping target: String, down: Set<String>) -> Set<String> {
    var kept = Set<String>()
    for other in Catalog.categories where other.id != target {
      if !down.isDisjoint(with: other.labels) { continue }
      kept.formUnion(Set(other.labels).intersection(category(target)))
    }
    return kept
  }

  func testDisableKeepsTheLabelsAnotherEnabledCategoryShares() throws {
    let shared = Set(category("store")).intersection(category("icloud"))
    XCTAssertFalse(shared.isEmpty)
    // iCloud is fully enabled, so stopping the store keeps what they share.
    let kept = expectedKept(stopping: "store", down: [])
    XCTAssertTrue(kept.isSuperset(of: shared))
    let host = host(loaded: Set(category("store")))
    try installPlists(host, labels: category("store"))
    let out = try simctl(host).disableServices(udid: udid, ids: ["store"])
    XCTAssertEqual(Set(out.stillEnabled), kept)
    XCTAssertEqual(Set(out.labels), Set(category("store")).subtracting(kept))
    XCTAssertTrue(host.disabled[udid]!.isDisjoint(with: kept))

    // Once iCloud has a daemon down it is no longer "on", so what only it
    // shared goes too.
    let down = category("icloud").first { !shared.contains($0) }!
    let kept2 = expectedKept(stopping: "store", down: [down])
    XCTAssertTrue(kept2.count < kept.count)
    let host2 = self.host(disabled: [down], loaded: Set(category("store")))
    try installPlists(host2, labels: category("store"))
    let out2 = try simctl(host2).disableServices(udid: udid, ids: ["store"])
    XCTAssertEqual(Set(out2.stillEnabled), kept2)
    XCTAssertTrue(host2.disabled[udid]!.isSuperset(of: shared.subtracting(kept2)))
  }

  func testDisableOfANamedLabelIsAlwaysStopped() throws {
    let shared = Set(category("store")).intersection(category("icloud")).sorted()[0]
    let host = host(loaded: [shared])
    try installPlists(host, labels: [shared])
    let out = try simctl(host).disableServices(udid: udid, ids: [shared])
    XCTAssertEqual(out.labels, [shared])
    XCTAssertEqual(out.stillEnabled, [])
  }

  func testANamedLabelIsStoppedEvenWhenItsCategoryAlsoNamesItAndANeighbourSharesIt() throws {
    let shared = Set(category("store")).intersection(category("icloud")).sorted()[0]
    let host = host(loaded: Set(category("store")))
    try installPlists(host, labels: category("store"))
    let out = try simctl(host).disableServices(udid: udid, ids: ["store", shared])
    XCTAssertTrue(out.labels.contains(shared), "named on its own, so it is stopped")
    XCTAssertFalse(out.stillEnabled.contains(shared))
    XCTAssertTrue(host.disabled[udid]!.contains(shared))
  }

  func testDisableKeepsHomedOnWatchOS() throws {
    let health = Catalog.categories.first { $0.labels.contains("com.apple.homed") }!
    let host = host(runtime: watch, loaded: Set(health.labels))
    try installPlists(host, labels: health.labels)
    let out = try simctl(host).disableServices(udid: udid, ids: [health.id])
    XCTAssertTrue(out.stillEnabled.contains("com.apple.homed"))
    XCTAssertFalse(out.labels.contains("com.apple.homed"))
    XCTAssertFalse(host.disabled[udid]!.contains("com.apple.homed"))
  }

  func testDisableRefusesACompatibilityDaemon() throws {
    let host = host()
    let compat = Catalog.managedSet.subtracting(Catalog.slimmableSet).sorted()[0]
    XCTAssertThrowsError(try simctl(host).disableServices(udid: udid, ids: [compat])) {
      XCTAssertEqual(
        "\($0)",
        "\(compat) is never disabled: simslim keeps it running for compatibility (see `simslim profiles`)"
      )
    }
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testDisableReportsOverridesThatDidNotTake() throws {
    let label = category("search")[0]
    let host = host(loaded: [label])
    host.failTransition = { _, l in l == label ? CommandResult(status: 1) : nil }
    XCTAssertThrowsError(try simctl(host).disableServices(udid: udid, ids: [label]))
  }

  func testDisableOnAShutdownSimulatorNeedsSave() throws {
    let host = host(state: "Shutdown")
    XCTAssertThrowsError(try simctl(host).disableServices(udid: udid, ids: ["search"]))
    XCTAssertTrue(spawnVerbs(host).isEmpty)
  }

  // MARK: - --save

  func testSaveAddsInOrderWithoutDuplicates() throws {
    try writeProfile(#"{"name":"mine","except":["siri"],"keep":["\#(category("siri")[0])"]}"#)
    let keepable = category("search")[0]
    let (data, changed) = try updatedProfile(
      path: profilePath, categories: ["icloud", "siri"], labels: [keepable], enable: true)
    XCTAssertTrue(changed)
    let parsed = try parseSlimProfile(XCTUnwrap(data), path: profilePath)
    XCTAssertEqual(parsed.except, ["siri", "icloud"])
    XCTAssertEqual(parsed.name, "mine")
  }

  func testSaveSkipsADaemonAnExceptedCategoryAlreadyKeeps() throws {
    try writeProfile(#"{"except":["search"]}"#)
    let covered = category("search")[0]
    let (data, changed) = try updatedProfile(
      path: profilePath, categories: [], labels: [covered], enable: true)
    XCTAssertFalse(changed)
    XCTAssertNil(data)
  }

  func testSaveCreatesAMissingFileFromTheDefaultProfile() throws {
    XCTAssertFalse(FileManager.default.fileExists(atPath: profilePath))
    try saveServices(path: profilePath, categories: ["search"], labels: [], enable: true)
    XCTAssertEqual(try loadSlimProfile(path: profilePath).exceptCategories, ["search"])
    // Disabling from a missing file still creates it, as the default profile.
    let other = root + "/other.json"
    try saveServices(path: other, categories: ["search"], labels: [], enable: false)
    XCTAssertTrue(FileManager.default.fileExists(atPath: other))
  }

  func testSaveLeavesAnUnchangedProfileUntouched() throws {
    try writeProfile(#"{"except":["search"]}"#)
    let before = try FileManager.default.attributesOfItem(atPath: profilePath)[.systemFileNumber]
    try saveServices(path: profilePath, categories: ["search"], labels: [], enable: true)
    let after = try FileManager.default.attributesOfItem(atPath: profilePath)[.systemFileNumber]
    XCTAssertEqual(before as? UInt64, after as? UInt64, "not rewritten")
    XCTAssertEqual(
      try String(contentsOfFile: profilePath, encoding: .utf8), #"{"except":["search"]}"#)
  }

  func testSaveDisableRemovesAndRefusesToLeaveACategoryKeepingTheDaemon() throws {
    let label = category("search")[0]
    try writeProfile(#"{"except":["search","siri"],"keep":["\#(label)"]}"#)
    XCTAssertThrowsError(
      try updatedProfile(path: profilePath, categories: [], labels: [label], enable: false)
    ) {
      XCTAssertEqual(
        "\($0)",
        "profile \(profilePath) keeps \(label) enabled through category \"search\"; disable that category instead, or edit the file"
      )
    }
    try saveServices(path: profilePath, categories: ["search"], labels: [label], enable: false)
    let profile = try parseSlimProfile(
      Data(contentsOf: URL(fileURLWithPath: profilePath)), path: profilePath)
    XCTAssertEqual(profile.except, ["siri"])
    XCTAssertEqual(profile.keep, [])
  }

  func testSaveRewritesAtomicallyKeepingModeAndFollowingSymlinks() throws {
    let real = root + "/real.json"
    try #"{"except":[]}"#.write(toFile: real, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real)
    try FileManager.default.createSymbolicLink(atPath: profilePath, withDestinationPath: real)
    try saveServices(path: profilePath, categories: ["search"], labels: [], enable: true)
    let link = try FileManager.default.destinationOfSymbolicLink(atPath: profilePath)
    XCTAssertEqual(link, real, "the symlink survives")
    XCTAssertEqual(try loadSlimProfile(path: real).exceptCategories, ["search"])
    let mode = try FileManager.default.attributesOfItem(atPath: real)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: root).filter {
      $0.hasPrefix(".")
    }
    XCTAssertEqual(leftovers, [])
  }

  func testAnInvalidProfileFailsBeforeTheSimulatorChanges() throws {
    try writeProfile(#"{"except":["no-such-category"]}"#)
    let host = host(disabled: Set(category("search")))
    XCTAssertThrowsError(
      try simctl(host).enableServices(udid: udid, ids: ["search"], save: profilePath))
    XCTAssertEqual(host.disabled[udid], Set(category("search")), "nothing was changed")
    XCTAssertTrue(spawnVerbs(host).isEmpty)
  }

  func testAFailedLiveChangeLeavesTheProfileAlone() throws {
    let label = category("search")[0]
    try writeProfile(#"{"except":[]}"#)
    let host = host(disabled: [label])
    host.failTransition = { _, l in l == label ? CommandResult(status: 1) : nil }
    XCTAssertThrowsError(
      try simctl(host).enableServices(udid: udid, ids: [label], save: profilePath)
    ) {
      XCTAssertTrue("\($0)".hasSuffix("(profile \(profilePath) not changed)"), "\($0)")
    }
    XCTAssertEqual(try String(contentsOfFile: profilePath, encoding: .utf8), #"{"except":[]}"#)
  }

  func testAFailedSaveAfterALiveChangeSaysSo() throws {
    let host = host(loaded: Set(category("search")))
    try installPlists(host, labels: category("search"))
    // The directory vanishes between validation and the write.
    let ghost = root + "/missing-dir/profile.json"
    XCTAssertThrowsError(
      try simctl(host).enableServices(udid: udid, ids: ["search"], save: ghost)
    ) {
      XCTAssertTrue(
        "\($0)".hasPrefix("the simulator was changed, but profile \(ghost) was not: "), "\($0)")
    }
  }

  func testIDsAreDeduplicatedAndSorted() throws {
    let (categories, labels) = try simctl(host()).resolveServiceIDs([
      "siri", "search", "siri", category("search")[0], category("search")[0],
    ])
    XCTAssertEqual(categories, ["search", "siri"])
    XCTAssertEqual(labels, [category("search")[0]])
  }

  // MARK: - from the independent review

  func testDisableFailsWhenTheOverrideIsAcceptedButNeverAppears() throws {
    let label = category("search")[0]
    let host = host(loaded: [label])
    // launchctl exits 0 for `disable` but nothing changes: only the read-back sees it.
    host.failTransition = { verb, l in
      verb == "disable" && l == label ? CommandResult(status: 0) : nil
    }
    XCTAssertThrowsError(try simctl(host).disableServices(udid: udid, ids: [label])) {
      XCTAssertEqual("\($0)", "1 of 1 disable overrides did not take")
    }
  }

  func testWithoutARuntimeRootEveryUnloadedLabelCountsAsOneLaunchdShouldLoad() throws {
    let label = category("search")[0]
    let host = host(disabled: [label])  // no runtime roots: plists cannot be looked up
    let out = try simctl(host).enableServices(udid: udid, ids: [label])
    XCTAssertEqual(host.disabled[udid], [])
    XCTAssertEqual(out.notStarted, [label], "re-enabled, but not loaded in this boot")
  }

  func testDisableValidatesTheProfileBeforeTouchingTheSimulator() throws {
    let label = category("search")[0]
    try writeProfile(#"{"except":["search"],"keep":["\#(label)"]}"#)
    let host = host(loaded: Set(category("search")))
    XCTAssertThrowsError(
      try simctl(host).disableServices(udid: udid, ids: [label], save: profilePath))
    XCTAssertEqual(host.disabled[udid], [])
    XCTAssertTrue(spawnVerbs(host).filter { !["print-disabled", "list"].contains($0) }.isEmpty)
  }

  func testAFailedLiveDisableLeavesTheProfileAlone() throws {
    let label = category("search")[0]
    try writeProfile(#"{"except":["siri"],"keep":["\#(label)"]}"#)
    let host = host(loaded: [label])
    host.failTransition = { _, l in l == label ? CommandResult(status: 1) : nil }
    XCTAssertThrowsError(
      try simctl(host).disableServices(udid: udid, ids: [label], save: profilePath)
    ) {
      XCTAssertTrue("\($0)".hasSuffix("(profile \(profilePath) not changed)"), "\($0)")
    }
    XCTAssertTrue(try String(contentsOfFile: profilePath, encoding: .utf8).contains(label))
  }

  func testDisablingOnlyWhatThePlatformKeepsStopsNothing() throws {
    let host = host(runtime: watch, loaded: ["com.apple.homed"])
    let out = try simctl(host).disableServices(udid: udid, ids: ["com.apple.homed"])
    XCTAssertEqual(out.labels, [])
    XCTAssertEqual(out.stillEnabled, ["com.apple.homed"])
    XCTAssertTrue(spawnVerbs(host).filter { !["print-disabled", "list"].contains($0) }.isEmpty)
  }

  func testWhitespacePaddedEntriesAreFoundNotDuplicated() throws {
    try writeProfile(#"{"except":[" search "],"keep":["  "]}"#)
    // Disabling finds the padded category and removes it.
    try saveServices(path: profilePath, categories: ["search"], labels: [], enable: false)
    XCTAssertEqual(
      try parseSlimProfile(Data(contentsOf: URL(fileURLWithPath: profilePath)), path: "p").except,
      [])
    // Enabling a category already present padded does not add it again.
    try writeProfile(#"{"except":[" search "]}"#)
    let (data, changed) = try updatedProfile(
      path: profilePath, categories: ["search"], labels: [], enable: true)
    XCTAssertFalse(changed)
    XCTAssertNil(data)
  }

  func testASymlinkNamedWithABareFileNameIsFollowed() throws {
    let target = root + "/shared.json"
    try #"{"except":[]}"#.write(toFile: target, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
    let cwd = FileManager.default.currentDirectoryPath
    defer { FileManager.default.changeCurrentDirectoryPath(cwd) }
    FileManager.default.changeCurrentDirectoryPath(root)
    try FileManager.default.createSymbolicLink(
      atPath: root + "/link.json", withDestinationPath: "shared.json")
    try saveServices(path: "link.json", categories: ["search"], labels: [], enable: true)
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: root + "/link.json"),
      "shared.json", "still a symlink")
    XCTAssertEqual(try loadSlimProfile(path: target).exceptCategories, ["search"])
    let mode = try FileManager.default.attributesOfItem(atPath: target)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
  }

  func testAProfilePathThatCannotBeReadIsNeverOverwrittenAsAMissingFile() throws {
    // A symlink loop is an error (ELOOP), not a missing file to start afresh.
    try FileManager.default.createSymbolicLink(
      atPath: root + "/loop.json", withDestinationPath: root + "/loop.json")
    XCTAssertThrowsError(
      try saveServices(
        path: root + "/loop.json", categories: ["search"], labels: [], enable: true))
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: root + "/loop.json"),
      root + "/loop.json", "the symlink was not replaced")
  }
}
