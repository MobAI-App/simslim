import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class DiskCommandTests: XCTestCase {
  private let udid = "AAAAAAAA-0000-0000-0000-000000000001"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-diskcli-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private var dataPath: String { "\(root)/\(udid)/data" }

  private func write(_ relative: String, size: Int = 8192) throws {
    let path = "\(dataPath)/\(relative)"
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(count: size).write(to: URL(fileURLWithPath: path))
  }

  private func exists(_ relative: String) -> Bool {
    var info = stat()
    return lstat("\(dataPath)/\(relative)", &info) == 0
  }

  private func host(state: String = "Shutdown") -> FakeHost {
    let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", state: state)])
    host.dataRoot = root
    host.duKiB["\(root)/\(udid)"] = 100
    if state == "Booted" { host.disabled[udid] = [] }
    return host
  }

  private func subcommands(_ host: FakeHost) -> [String] {
    host.calls.compactMap { $0.executable == .xcrun ? $0.arguments.dropFirst().first : nil }
  }

  // MARK: - size

  func testSize() throws {
    let host = host()
    try FileManager.default.createDirectory(
      atPath: dataPath, withIntermediateDirectories: true)
    host.duKiB["\(root)/\(udid)"] = 6_710_886  // 6.40 GB
    let r = runCLI(["size", udid], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "\(udid): 6.40 GB on disk\n")
    let json = runCLI(["size", udid, "--json"], host: host)
    let decoded = try JSONDecoder().decode(
      SimulatorDiskMeasurement.self, from: Data(json.stdout.utf8))
    XCTAssertEqual(decoded.bytes, 6_710_886 * 1024)
  }

  func testSizeNeedsAnExactUDID() {
    XCTAssertEqual(runCLI(["size"], host: host()).status, 1)
    let host = host()
    let r = runCLI(["size", "all"], host: host)
    XCTAssertEqual(r.stderr, "simslim: no simulator with udid all\n")
    XCTAssertFalse(host.calls.contains { $0.executable == .du })
  }

  // MARK: - disk-categories

  func testCategoriesText() {
    let r = runCLI(["disk-categories"], host: FakeHost())
    XCTAssertEqual(r.status, 0)
    let lines = r.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 10)
    XCTAssertEqual(
      lines[0], "caches                 System & App Caches          Lower risk · cleanable")
    XCTAssertEqual(
      lines[1],
      "                       Next launches may be slower; downloaded or offline cache content can disappear."
    )
    XCTAssertTrue(lines[8].hasPrefix("required-siri-assets   Required Siri Assets"))
    XCTAssertTrue(lines[8].hasSuffix("System managed · measured only"))
    XCTAssertEqual(
      runCLI(["disk-categories", "x"], host: FakeHost()).stderr,
      "simslim: disk-categories takes no arguments\n")
  }

  func testCategoriesDecodeAsTheAppsModel() throws {
    let r = runCLI(["disk-categories", "--json"], host: FakeHost())
    let categories = try JSONDecoder().decode([DiskCleanupCategory].self, from: Data(r.stdout.utf8))
    XCTAssertEqual(
      categories.map(\.id),
      [
        "caches", "logs", "temporary", "linguistic-data", "required-siri-assets",
      ])
    XCTAssertEqual(categories.filter(\.defaultSelected).map(\.id), ["caches", "logs", "temporary"])
    XCTAssertEqual(categories.filter { !$0.canClean }.map(\.id), ["required-siri-assets"])
  }

  // MARK: - disk-plan

  func testPlanDecodesAsTheAppsModelAndPrintsATable() throws {
    try write("Library/Caches/c.bin", size: 100_000)
    try write("Containers/Bundle/Application/APP/Example.app/Example", size: 50_000)
    try write("Containers/Data/Application/D/Documents/d.bin", size: 30_000)
    let host = host()
    let json = runCLI(["disk-plan", "--json", udid], host: host)
    XCTAssertEqual(json.status, 0, json.stderr)
    let plan = try JSONDecoder().decode(SimulatorDiskCleanupPlan.self, from: Data(json.stdout.utf8))
    XCTAssertEqual(plan.udid, udid)
    XCTAssertGreaterThan(plan.bytes(for: "caches"), 100_000 - 1)
    XCTAssertGreaterThan(plan.storageBytes(for: "installed-apps"), 50_000 - 1)
    XCTAssertGreaterThan(plan.storageBytes(for: "documents"), 30_000 - 1)
    XCTAssertEqual(plan.cleanableBytes, plan.bytes(for: "caches"))

    let text = runCLI(["disk-plan", udid], host: host)
    XCTAssertTrue(text.stdout.hasPrefix("\(udid): "))
    XCTAssertTrue(text.stdout.contains(" currently cleanable\n"))
    XCTAssertTrue(text.stdout.contains("  caches                 "))
    XCTAssertTrue(text.stdout.contains("(iOS-managed; measured only)"))
    XCTAssertTrue(text.stdout.contains("  Stored data (read only)\n"))
    XCTAssertTrue(text.stdout.contains("    installed-apps       "))
    XCTAssertTrue(plan.categories.count == 5 && plan.storage.count == 4)
  }

  func testPlanChangesNothing() throws {
    try write("Library/Caches/c.bin")
    let host = host()
    XCTAssertEqual(runCLI(["disk-plan", udid], host: host).status, 0)
    XCTAssertTrue(exists("Library/Caches/c.bin"))
    XCTAssertFalse(subcommands(host).contains("shutdown"))
  }

  // MARK: - disk-clean

  func testCleanNeedsConfirmBeforeAnything() throws {
    try write("Library/Caches/c.bin")
    let host = host(state: "Booted")
    let r = runCLI(["disk-clean", udid, "--categories", "caches"], host: host)
    XCTAssertEqual(r.status, 1)
    XCTAssertEqual(
      r.stderr,
      "simslim: disk-clean permanently deletes data; pass --confirm after reviewing `simslim disk-plan \(udid)`\n"
    )
    XCTAssertTrue(host.calls.isEmpty, "not even a lookup")
    XCTAssertTrue(exists("Library/Caches/c.bin"))
  }

  func testCleanValidatesTheSelectionBeforeShuttingDownAnything() throws {
    try write("Library/Caches/c.bin")
    for (args, message) in [
      ([], "select at least one cleanable disk category"),
      (["--categories", "nope"], "unknown disk cleanup category \"nope\""),
      (["--categories", "required-siri-assets"], "measured only and cannot be cleaned"),
      (["--categories", "caches,required-siri-assets"], "measured only"),
    ] as [([String], String)] {
      let host = host(state: "Booted")
      let r = runCLI(["disk-clean", udid, "--confirm"] + args, host: host)
      XCTAssertEqual(r.status, 1, "\(args)")
      XCTAssertTrue(r.stderr.contains(message), r.stderr)
      XCTAssertFalse(subcommands(host).contains("shutdown"), "\(args)")
      XCTAssertTrue(exists("Library/Caches/c.bin"))
    }
  }

  func testCleanShutsTheSimulatorDownBeforeDeletingAndLeavesItOff() throws {
    try write("Library/Caches/c.bin")
    let host = host(state: "Booted")
    let atShutdown = Box()
    host.onCall = { _, args in
      if args.contains("shutdown") { atShutdown.set(self.exists("Library/Caches/c.bin")) }
    }
    let r = runCLI(
      ["disk-clean", udid, "--confirm", "--categories", "caches", "--json"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(atShutdown.value, true, "nothing was deleted before the shutdown")
    XCTAssertFalse(exists("Library/Caches/c.bin"))
    XCTAssertEqual(host.devices[0].state, "Shutdown")
    let result = try JSONDecoder().decode(
      SimulatorDiskCleanupResult.self, from: Data(r.stdout.utf8))
    XCTAssertEqual(result.categoryIds, ["caches"])
    XCTAssertTrue(result.wasBooted)
    XCTAssertFalse(result.bootStateRestored)
    XCTAssertGreaterThan(result.reclaimedBytes, 0)
    XCTAssertEqual(result.reclaimedBytes, result.beforeBytes - result.afterBytes)
  }

  func testPreserveBootStateBootsItAgain() throws {
    try write("Library/Caches/c.bin")
    let host = host(state: "Booted")
    let r = runCLI(
      [
        "disk-clean", udid, "--confirm", "--categories", "caches", "--preserve-boot-state",
        "--json",
      ],
      host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(host.devices[0].state, "Booted")
    let result = try JSONDecoder().decode(
      SimulatorDiskCleanupResult.self, from: Data(r.stdout.utf8))
    XCTAssertTrue(result.wasBooted)
    XCTAssertTrue(result.bootStateRestored)
  }

  func testAShutdownSimulatorIsNotBootedByPreserveBootState() throws {
    try write("Library/Caches/c.bin")
    let host = host(state: "Shutdown")
    let r = runCLI(
      ["disk-clean", udid, "--confirm", "--categories", "caches", "--preserve-boot-state"],
      host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(host.devices[0].state, "Shutdown")
    XCTAssertFalse(subcommands(host).contains("boot"))
    XCTAssertTrue(r.stdout.hasPrefix("Cleaned \(udid) and reclaimed "))
    XCTAssertTrue(r.stdout.hasSuffix("on-demand assets may download again when needed.\n"))
  }

  func testNothingIsDeletedWhenTheShutdownFails() throws {
    try write("Library/Caches/c.bin")
    let host = host(state: "Booted")
    host.shutdownFailure = "cannot shut down"
    let r = runCLI(["disk-clean", udid, "--confirm", "--categories", "caches"], host: host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("cannot shut down"))
    XCTAssertTrue(exists("Library/Caches/c.bin"), "the simulator is still running on these files")
  }

  func testAFailedRebootIsReportedButTheCleanupStands() throws {
    try write("Library/Caches/c.bin")
    let host = host(state: "Booted")
    host.bootFailure = "boot refused"
    let r = runCLI(
      ["disk-clean", udid, "--confirm", "--categories", "caches", "--preserve-boot-state"],
      host: host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(
      r.stderr.contains("disk cleanup finished, but could not restore boot state: "), r.stderr)
    XCTAssertFalse(exists("Library/Caches/c.bin"))
  }

  func testCleanNeverReachesAnAliasOrAnyPath() throws {
    try write("Library/Caches/c.bin")
    for target in ["all", "booted", "..", "/", "\(udid)/.."] {
      let host = host(state: "Booted")
      let r = runCLI(["disk-clean", target, "--confirm", "--categories", "caches"], host: host)
      XCTAssertEqual(r.status, 1, target)
      XCTAssertFalse(subcommands(host).contains("shutdown"), target)
    }
    XCTAssertTrue(exists("Library/Caches/c.bin"))
  }

  func testCleanRefusesADataDirectoryThatIsASymlink() throws {
    try FileManager.default.createDirectory(
      atPath: root + "/elsewhere/Library/Caches", withIntermediateDirectories: true)
    try Data(count: 4096).write(to: URL(fileURLWithPath: root + "/elsewhere/Library/Caches/x.bin"))
    try FileManager.default.createDirectory(
      atPath: "\(root)/\(udid)", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: dataPath, withDestinationPath: root + "/elsewhere")
    let host = host(state: "Booted")
    let r = runCLI(["disk-clean", udid, "--confirm", "--categories", "caches"], host: host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("simulator data path is not a real directory"), r.stderr)
    XCTAssertFalse(subcommands(host).contains("shutdown"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/elsewhere/Library/Caches/x.bin"))
  }

  func testCleanOnlyTouchesTheRequestedCategories() throws {
    try write("Library/Caches/c.bin")
    try write("Library/Logs/l.log")
    try write("Containers/Data/Application/A/tmp/t.bin")
    let r = runCLI(
      ["disk-clean", udid, "--confirm", "--categories", "logs"], host: host(state: "Shutdown"))
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertFalse(exists("Library/Logs/l.log"))
    XCTAssertTrue(exists("Library/Caches/c.bin"))
    XCTAssertTrue(exists("Containers/Data/Application/A/tmp/t.bin"))
  }
}

private final class Box: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Bool?
  func set(_ value: Bool) {
    lock.lock()
    stored = value
    lock.unlock()
  }
  var value: Bool? {
    lock.lock()
    defer { lock.unlock() }
    return stored
  }
}
