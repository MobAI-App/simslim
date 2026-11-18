// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class MutationCommandTests: XCTestCase {
  private let udid = "AAAAAAAA-0000-0000-0000-000000000001"
  private var root = ""

  override func setUpWithError() throws {
    root = NSTemporaryDirectory() + "simslim-cli-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private func host(state: String, runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
    -> FakeHost
  {
    let host = FakeHost(devices: [.init(udid: udid, name: "iPhone", runtime: runtime, state: state)]
    )
    host.storeRoot = root
    if state == "Booted" { host.disabled[udid] = [] }
    return host
  }

  private func run(_ args: [String], _ host: FakeHost) -> CLIResult {
    runCLI(args, host: host, storeRoot: root)
  }

  private func subcommands(_ host: FakeHost) -> [String] {
    host.calls.compactMap { $0.executable == .xcrun ? $0.arguments.dropFirst().first : nil }
  }

  // MARK: - boot / shutdown

  func testBootAnAlreadyBootedSimulatorDoesNothing() {
    let host = host(state: "Booted")
    let r = run(["boot", udid], host)
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stdout, "Simulator \(udid) is already booted.\n")
    XCTAssertFalse(subcommands(host).contains("boot"))
  }

  func testBootJSONIsCleanAndQuiet() throws {
    let host = host(state: "Shutdown")
    let r = run(["boot", udid, "--json"], host)
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stderr, "", "no progress chatter under --json")
    let result = try JSONDecoder().decode(
      SimulatorMutationOutput.self, from: Data(r.stdout.utf8))
    XCTAssertEqual(result, SimulatorMutationOutput(action: "boot", udid: udid))
    XCTAssertEqual(host.devices[0].state, "Booted")
  }

  func testBootAnUnknownUDIDOrAliasNeverReachesSimctlBoot() {
    for target in ["all", "booted", "00000000-0000-0000-0000-000000000000"] {
      let host = host(state: "Shutdown")
      let r = run(["boot", target], host)
      XCTAssertEqual(r.status, 1, target)
      XCTAssertEqual(r.stderr, "simslim: no simulator with udid \(target)\n")
      XCTAssertFalse(subcommands(host).contains("boot"), target)
      XCTAssertFalse(subcommands(host).contains("shutdown"), target)
    }
  }

  func testBootFailureIsReported() {
    let host = host(state: "Shutdown")
    host.bootFailure = "Unable to boot: no runtime"
    let r = run(["boot", udid], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("simctl boot: exit status 1: Unable to boot: no runtime"))
  }

  func testShutdownWaitsUntilShutdown() {
    let host = host(state: "Booted")
    let r = run(["shutdown", udid], host)
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stdout, "Shut down \(udid).\n")
    XCTAssertEqual(host.devices[0].state, "Shutdown")
  }

  func testShutdownOfAShutdownSimulatorDoesNothing() {
    let host = host(state: "Shutdown")
    let r = run(["shutdown", udid, "--json"], host)
    XCTAssertEqual(r.status, 0)
    XCTAssertTrue(r.stdout.contains("\"action\" : \"shutdown\""))
    XCTAssertFalse(subcommands(host).contains("shutdown"))
  }

  func testShutdownAliasNeverReachesSimctl() {
    let host = host(state: "Booted")
    XCTAssertEqual(run(["shutdown", "all"], host).status, 1)
    XCTAssertFalse(subcommands(host).contains("shutdown"))
  }

  // MARK: - on

  func testOnRejectsNoRebootWithPreserveBootStateBeforeAnyWork() {
    let host = host(state: "Shutdown")
    let r = run(["on", udid, "--no-reboot", "--preserve-boot-state"], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("--no-reboot cannot be combined with --preserve-boot-state"))
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testOnValidatesTheProfileBeforeTouchingTheSimulator() {
    let host = host(state: "Shutdown")
    let r = run(["on", udid, "--except", "no-such-category"], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("unknown category \"no-such-category\""))
    XCTAssertTrue(host.calls.isEmpty)
    XCTAssertEqual(run(["on", udid, "--profile", "x.json", "--keep", "a"], host).status, 1)
    XCTAssertTrue(host.calls.isEmpty)
  }

  func testOnSlimsAShutdownSimulatorAndBootsIt() {
    let host = host(state: "Shutdown")
    let r = run(["on", udid], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Done. Simulator reconfigured slim and booted.\n")
    XCTAssertTrue(r.stderr.hasPrefix("Slimming \(udid): disabling "))
    XCTAssertEqual(host.devices[0].state, "Booted")
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), Profile().desired())
  }

  func testOnPreserveBootStateReturnsToShutdown() {
    let host = host(state: "Shutdown")
    let r = run(["on", udid, "--preserve-boot-state"], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Done. Simulator reconfigured slim and returned to shutdown.\n")
    XCTAssertEqual(host.devices[0].state, "Shutdown")
    // The next boot comes up slim from the stored overrides.
    XCTAssertEqual(run(["boot", udid], host).status, 0)
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), Profile().desired())
  }

  func testOnPreserveBootStateStillShutsDownWhenTheOperationFails() {
    let host = host(state: "Shutdown")
    // The boot starts and the device stays Booted, but never becomes ready.
    host.bootstatusFailure = "Unable to wait for boot"
    let r = run(["on", udid, "--preserve-boot-state"], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("Unable to wait for boot"), r.stderr)
    XCTAssertEqual(host.devices[0].state, "Shutdown", "the restore ran despite the failure")
    XCTAssertTrue(subcommands(host).contains("shutdown"))
  }

  func testOnReportsBothFailuresWhenTheShutdownRestoreFailsToo() {
    let host = host(state: "Shutdown")
    host.bootstatusFailure = "boot never ready"
    host.shutdownFailure = "shutdown refused"
    let r = run(["on", udid, "--preserve-boot-state"], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(
      r.stderr.hasSuffix(
        "simslim: xcrun simctl bootstatus \(udid) -b: exit status 1: boot never ready; additionally could not "
          + "restore original shutdown state: restore original shutdown state: "
          + "simctl shutdown: exit status 1: shutdown refused\n"), r.stderr)
  }

  func testOnlyTheRestoreFailingIsReportedOnItsOwn() {
    let host = host(state: "Shutdown")
    host.shutdownFailure = "shutdown refused"
    let r = run(["on", udid, "--preserve-boot-state"], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(
      r.stderr.hasSuffix(
        "simslim: restore original shutdown state: simctl shutdown: exit status 1: shutdown refused\n"
      ), r.stderr)
  }

  func testEveryMutationStaysInTheDeviceSetItLivesIn() {
    // The fake only shows a device through its own --set, like simctl, so a
    // command that lost the set would fail with "Invalid device".
    for token in ["testing", "/custom/set"] {
      let extra: [String] = token == "testing" ? [] : ["--set", token]
      for state in ["Shutdown", "Booted"] {
        let host = FakeHost(devices: [])
        host.sets[token] = [.init(udid: udid, name: "iPhone", state: state)]
        host.storeRoot = root
        if state == "Booted" { host.disabled[udid] = [] }
        for command in [["on"], ["on", "--no-reboot"], ["off"], ["boot"], ["shutdown"]] {
          let r = runCLI(
            extra + [command[0], udid] + command.dropFirst(), host: host, storeRoot: root)
          XCTAssertEqual(r.status, 0, "\(token) \(state) \(command): \(r.stderr)")
        }
      }
    }
  }

  func testOnAlreadySlimChangesNothing() {
    let host = host(state: "Booted")
    host.disabled[udid] = Profile().desired()
    let r = run(["on", udid], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Already slim. Nothing to change.\n")
    XCTAssertFalse(subcommands(host).contains("shutdown"))
  }

  func testOnRefusesAnOldRuntimeAndSuggestsNoReboot() {
    let host = host(
      state: "Booted", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
    let r = run(["on", udid], host)
    XCTAssertEqual(r.status, 1)
    XCTAssertTrue(r.stderr.contains("iOS 17.0 runtime cannot persist"), r.stderr)
    XCTAssertTrue(r.stderr.contains("--no-reboot"))
    XCTAssertFalse(subcommands(host).contains("shutdown"))
    XCTAssertFalse(subcommands(host).contains("spawn"))
  }

  func testOnNoRebootOnAnOldRuntimeSaysTheSlimIsLostAtReboot() {
    let host = host(
      state: "Booted", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
    host.loaded[udid] = []
    let r = run(["on", udid, "--no-reboot"], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertTrue(
      r.stdout.contains("Done. Simulator slimmed for this boot session without a reboot."))
    XCTAssertTrue(r.stdout.contains("iOS 17.0 cannot persist overrides"), r.stdout)
    XCTAssertFalse(subcommands(host).contains("shutdown"))
  }

  func testOnExceptKeepsThatCategoryEnabled() {
    let host = host(state: "Shutdown")
    let r = run(["on", udid, "--except", "siri"], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    let siri = Set(Catalog.category(id: "siri")!.labels)
    let slim = host.disabled[udid]!.intersection(Catalog.managedSet)
    XCTAssertTrue(slim.isDisjoint(with: siri.subtracting(Catalog.category(id: "store")!.labels)))
    XCTAssertEqual(slim, Profile(exceptCategories: ["siri"]).desired())
  }

  // MARK: - off

  func testOffRestoresStockAndReboots() {
    let host = host(state: "Booted")
    host.disabled[udid] = Profile().desired()
    let r = run(["off", udid], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Done. All daemons re-enabled and simulator rebooted.\n")
    XCTAssertEqual(host.disabled[udid]?.intersection(Catalog.managedSet), [])
    XCTAssertEqual(host.devices[0].state, "Booted")
  }

  func testOffAlreadyStock() {
    let host = host(state: "Booted")
    let r = run(["off", udid], host)
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stdout, "Already stock. Nothing to change.\n")
    XCTAssertFalse(subcommands(host).contains("shutdown"))
  }

  func testOffWorksOnARuntimeWithoutPersistence() {
    // Restoring stock is always allowed, even where slimming is refused.
    let host = host(
      state: "Booted", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-0")
    host.persistsOverrides = false
    host.disabled[udid] = ["com.apple.unmanaged"]
    let r = run(["off", udid], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Already stock. Nothing to change.\n")
  }

  func testOffPreserveBootStateOfAShutdownSimulator() {
    let host = host(state: "Shutdown")
    try? writeStoreLikeLaunchd(host, root: root, udid: udid, labels: Array(Profile().desired()))
    let r = run(["off", udid, "--preserve-boot-state"], host)
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "Done. All daemons re-enabled and simulator returned to shutdown.\n")
    XCTAssertEqual(host.devices[0].state, "Shutdown")
  }

  func testNoCommandAcceptsTwoUDIDs() {
    for command in ["boot", "shutdown", "on", "off"] {
      let r = run([command, udid, "other"], host(state: "Booted"))
      XCTAssertEqual(r.status, 1, command)
      XCTAssertTrue(r.stderr.contains("expected exactly one simulator UDID"), command)
    }
  }
}

/// Writes a store the way launchd_sim would, independently of the code under test.
private func writeStoreLikeLaunchd(_ host: FakeHost, root: String, udid: String, labels: [String])
  throws
{
  let dir = root + "/com.apple.CoreSimulator.SimDevice.\(udid)"
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let dict = Dictionary(uniqueKeysWithValues: labels.map { ($0, true) })
  let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
  try data.write(to: URL(fileURLWithPath: dir + "/disabled.plist"))
}
