import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class LiveCommandTests: XCTestCase {
  private let udid = "AAAAAAAA-0000-0000-0000-000000000001"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-livecli-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private var search: [String] { Catalog.category(id: "search")!.labels }

  private func host(state: String = "Booted", disabled: Set<String> = []) -> FakeHost {
    let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", state: state)])
    if state == "Booted" {
      host.disabled[udid] = disabled
      host.loaded[udid] = Set(search)  // loaded but disabled: only the override is lifted
    }
    return host
  }

  func testEnableWithNoUDIDOrNoIDs() {
    let none = runCLI(["enable"], host: host())
    XCTAssertEqual(none.status, 1)
    XCTAssertEqual(
      none.stderr,
      "simslim: expected a simulator UDID (see `simslim list`), then category IDs or launchd labels (see `simslim profiles`)\n"
    )
    let noIDs = runCLI(["enable", udid], host: host())
    XCTAssertEqual(noIDs.status, 1)
    XCTAssertTrue(
      noIDs.stderr.contains("name at least one category ID or managed daemon to enable"))
  }

  func testEnableTextOutput() {
    let host = host(disabled: Set(search))
    let r = runCLI(["enable", udid, "search"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(
      r.stdout,
      "Enabled \(search.count) services on \(udid) without a reboot.\n"
        + "This lasts until the next `on` or `watch` pass; pass --save <profile.json> to keep it in a profile.\n"
    )
    XCTAssertTrue(r.stderr.contains("Starting \(search.count) background services"))
  }

  func testIDsMayBeCommaSeparatedOrRepeated() {
    let host = host(disabled: Set(search))
    let r = runCLI(["enable", udid, "search,siri", "search"], host: host, storeRoot: root)
    XCTAssertEqual(r.status, 0, r.stderr)
    let siri = Catalog.category(id: "siri")!.labels
    XCTAssertTrue(r.stdout.hasPrefix("Enabled \(Set(search + siri).count) services"), r.stdout)
  }

  func testEnableJSONIsCleanAndQuiet() throws {
    let host = host(disabled: Set(search))
    let r = runCLI(["enable", udid, "search", "--json"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stderr, "")
    let out = try JSONDecoder().decode(ServicesOutput.self, from: Data(r.stdout.utf8))
    XCTAssertEqual(out.action, "enable")
    XCTAssertTrue(out.live)
    XCTAssertEqual(out.labels, search.sorted())
    XCTAssertFalse(r.stdout.contains("notStarted"), "omitted when empty")
    XCTAssertFalse(r.stdout.contains("saved"))
  }

  func testDisableJSONKeepsLabelsAsAnEmptyArray() {
    let host = host()
    let label = Catalog.managedSet.subtracting(Catalog.slimmableSet).sorted()[0]
    XCTAssertEqual(runCLI(["disable", udid, label, "--json"], host: host).status, 1)
    // A shutdown simulator with --save: nothing live, labels is still `[]`.
    let shut = self.host(state: "Shutdown")
    let r = runCLI(
      ["disable", udid, "search", "--json", "--save", root + "/p.json"], host: shut)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertTrue(
      r.stdout.contains("\"labels\" : [\n\n  ]") || r.stdout.contains("\"labels\" : [ ]")
        || r.stdout.contains("\"labels\" : []"), r.stdout)
    XCTAssertTrue(r.stdout.contains("\"live\" : false"))
  }

  func testDisableTextOutputAndNothingToStop() {
    let host = host()
    host.loaded[udid] = Set(search)
    let r = runCLI(["disable", udid, "search"], host: host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertTrue(
      r.stdout.hasPrefix("Stopped \(search.count) services on \(udid) without a reboot.\n"))
  }

  func testSaveMessages() {
    let live = runCLI(
      ["enable", udid, "search", "--save", root + "/a.json"],
      host: host(disabled: Set(search)))
    XCTAssertEqual(live.status, 0, live.stderr)
    XCTAssertTrue(
      live.stdout.hasSuffix(
        "Saved to \(root)/a.json. Apply it later with `simslim on \(udid) --profile \(root)/a.json`.\n"
      ), live.stdout)
    let off = runCLI(
      ["enable", udid, "search", "--save", root + "/b.json"], host: host(state: "Shutdown"))
    XCTAssertEqual(off.status, 0, off.stderr)
    XCTAssertEqual(
      off.stdout,
      "Saved to \(root)/b.json; nothing was applied, the simulator is not booted. Apply it with `simslim on \(udid) --profile \(root)/b.json`.\n"
    )
  }

  func testAliasAndExtraFlagsAreRejected() {
    XCTAssertEqual(runCLI(["enable", "all", "search"], host: host()).status, 1)
    XCTAssertEqual(runCLI(["disable", "booted", "search"], host: host()).status, 1)
    XCTAssertEqual(runCLI(["enable", udid, "search", "--no-such"], host: host()).status, 1)
  }
}
