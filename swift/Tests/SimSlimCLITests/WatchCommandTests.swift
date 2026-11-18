// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

private final class Sink: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""
  func append(_ s: String) {
    lock.lock()
    text += s
    lock.unlock()
  }
  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return text
  }
}

final class WatchCommandTests: XCTestCase {
  private let udid = "AAAAAAAA-0000-0000-0000-000000000001"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-watchcli-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
      atPath: root + "/home/Library/Developer/CoreSimulator/Devices",
      withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  /// Runs `simslim <args>` until `until` holds for what it has printed, then
  /// interrupts it, as Ctrl-C would.
  private func watch(
    _ args: [String], host: FakeHost, until: @escaping (String, String) -> Bool
  ) -> (status: Int32, stdout: String, stderr: String) {
    let out = Sink()
    let err = Sink()
    let flag = InterruptFlag()
    let cli = CLI(
      version: "t", environment: [:], runner: host, storeRoot: root + "/store",
      home: root + "/home", interrupt: flag, stdout: { out.append($0) }, stderr: { err.append($0) })
    let status = Sink()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      status.append(String(cli.run(args)))
      done.signal()
    }
    let limit = Date().addingTimeInterval(10)
    while !until(out.value, err.value) && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    flag.trigger()
    XCTAssertEqual(done.wait(timeout: .now() + 15), .success, "watch stops on interrupt")
    return (Int32(status.value) ?? -1, out.value, err.value)
  }

  private func bootedHost() -> FakeHost {
    let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", state: "Booted")])
    host.disabled[udid] = []
    host.loaded[udid] = []
    return host
  }

  func testJSONEventsAreOneObjectPerLineAndTheDeviceEndsSlim() throws {
    let host = bootedHost()
    let r = watch(["watch", "--json", "--interval", "200ms"], host: host) { out, _ in
      out.contains("\"slimmed\"")
    }
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stderr, "", "stderr stays quiet under --json")
    let lines = r.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(
      lines,
      [
        "{\"event\":\"slimming\",\"udid\":\"\(udid)\",\"set\":\"default\"}",
        "{\"event\":\"slimmed\",\"udid\":\"\(udid)\",\"set\":\"default\"}",
      ])
    for line in lines {
      XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), Profile().desired())
  }

  func testTextModeAnnouncesTheSetsAndLogsEachDevice() {
    let host = bootedHost()
    let r = watch(
      ["watch", "--interval", "200ms", "--set", "/custom/set"], host: host
    ) { _, err in err.contains("watch: slimmed \(self.udid)") }
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stdout, "")
    XCTAssertTrue(
      r.stderr.hasPrefix(
        "Watching device sets [default, testing, /custom/set]; slimming each simulator before it boots where its runtime allows, and no-reboot as it boots. Ctrl-C to stop.\n"
      ), r.stderr)
    XCTAssertTrue(r.stderr.contains("watch: slimming \(udid) (set default)\n"))
    XCTAssertTrue(r.stderr.contains("watch: \(udid): Booting the simulator"))
  }

  func testExceptKeepsACategoryOutOfTheSlim() {
    let host = bootedHost()
    _ = watch(["watch", "--json", "--interval", "200ms", "--except", "search"], host: host) {
      out, _ in out.contains("\"slimmed\"")
    }
    let search = Set(Catalog.category(id: "search")!.labels)
    XCTAssertTrue(host.disabled[udid]!.isDisjoint(with: search))
  }

  func testBadArgumentsFailBeforeAnythingRuns() {
    let host = bootedHost()
    let flag = InterruptFlag()
    func run(_ args: [String]) -> CLIResult {
      let err = Sink()
      let cli = CLI(
        version: "t", environment: [:], runner: host, home: root + "/home", interrupt: flag,
        stdout: { _ in }, stderr: { err.append($0) })
      let status = cli.run(args)
      return CLIResult(status: status, stdout: "", stderr: err.value)
    }
    let interval = run(["watch", "--interval", "soon"])
    XCTAssertEqual(interval.status, 1)
    XCTAssertTrue(interval.stderr.hasPrefix("simslim: invalid value \"soon\" for flag -interval"))
    XCTAssertTrue(
      run(["watch", "--profile", "x.json", "--keep", "a"]).stderr.contains(
        "--profile cannot be combined with --except or --keep"))
    XCTAssertTrue(run(["watch", "--except", "nope"]).stderr.contains("unknown category \"nope\""))
    XCTAssertTrue(run(["watch", udid]).stderr.contains("watch takes no arguments"))
    XCTAssertTrue(host.calls.isEmpty)
    XCTAssertFalse(flag.isSet)
  }
}
