// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

final class DispatchTests: XCTestCase {
  func testVersion() {
    for arguments in [["version"], ["--version"], ["-v"]] {
      let result = runCLI(arguments)
      XCTAssertEqual(result.stdout, "simslim test-version\n")
      XCTAssertEqual(result.status, 0)
    }
  }

  func testHelpAndNoArguments() {
    for arguments in [["help"], ["--help"], ["-h"]] {
      let result = runCLI(arguments)
      XCTAssertEqual(result.status, 0)
      XCTAssertTrue(result.stdout.hasPrefix("simslim runs more iOS"))
    }
    let none = runCLI([])
    XCTAssertEqual(none.status, 2)
    XCTAssertTrue(none.stdout.hasPrefix("simslim runs more iOS"))
  }

  func testUnknownCommandPrintsUsageAndExitsTwo() {
    let result = runCLI(["bogus"])
    XCTAssertEqual(result.status, 2)
    XCTAssertEqual(result.stderr, "unknown command \"bogus\"\n\n")
    XCTAssertTrue(result.stdout.contains("COMMANDS"))
  }

  func testEveryDispatchedCommandIsInTheUsageText() {
    XCTAssertFalse(usageText.contains("†"), "no command is left unported")
    for command in CLI.commandSpecs.keys {
      XCTAssertTrue(usageText.contains("  \(command)"), "\(command) is missing from the usage text")
    }
  }

  func testGlobalOptionsMayPrecedeOrFollowTheCommand() {
    let host = FakeHost(devices: [.init(udid: "A", name: "d")])
    host.sets["/custom"] = [.init(udid: "C", name: "custom one")]
    for arguments in [
      ["--set", "/custom", "list"], ["list", "--set", "/custom"], ["list", "--set=/custom"],
    ] {
      let result = runCLI(arguments, host: host)
      XCTAssertEqual(result.status, 0, "\(arguments)")
      XCTAssertTrue(result.stdout.contains("custom one"), "\(arguments)")
      XCTAssertTrue(result.stdout.contains("(/custom)"), "the set is shown for non-default sets")
    }
  }

  func testSetNeedsAValue() {
    for arguments in [["list", "--set"], ["list", "--set", ""], ["list", "--set", " , "]] {
      let result = runCLI(arguments)
      XCTAssertEqual(
        result.stderr, "simslim: --set requires a device set name (such as `testing`) or a path\n",
        "\(arguments)")
      XCTAssertEqual(result.status, 1)
    }
  }

  func testTimeoutOptions() {
    let host = standardHost()
    _ = runCLI(["status", bootedUDID, "--spawn-timeout", "5m"], host: host)
    XCTAssertEqual(host.calls.last { $0.arguments.contains("print-disabled") }?.timeout, 300)

    let envHost = standardHost()
    _ = runCLI(
      ["status", bootedUDID], host: envHost, environment: ["SIMSLIM_SPAWN_TIMEOUT": "90s"])
    XCTAssertEqual(envHost.calls.last { $0.arguments.contains("print-disabled") }?.timeout, 90)

    let defaultHost = standardHost()
    _ = runCLI(["status", bootedUDID], host: defaultHost)
    XCTAssertEqual(defaultHost.calls.last { $0.arguments.contains("print-disabled") }?.timeout, 120)

    let flagWins = standardHost()
    _ = runCLI(
      ["status", bootedUDID, "--spawn-timeout", "10s"], host: flagWins,
      environment: ["SIMSLIM_SPAWN_TIMEOUT": "90s"])
    XCTAssertEqual(flagWins.calls.last { $0.arguments.contains("print-disabled") }?.timeout, 10)
  }

  func testInvalidTimeouts() {
    var result = runCLI(["profiles", "--boot-timeout", "0"])
    XCTAssertEqual(
      result.stderr, "simslim: --boot-timeout must be a positive duration (such as `15m`)\n")
    result = runCLI(["profiles", "--spawn-timeout", "-1m"])
    XCTAssertEqual(
      result.stderr, "simslim: --spawn-timeout must be a positive duration (such as `2m`)\n")
    result = runCLI(["profiles", "--boot-timeout", "soon"])
    XCTAssertEqual(
      result.stderr,
      "simslim: invalid value \"soon\" for flag -boot-timeout: time: invalid duration \"soon\"\n")
    result = runCLI(["profiles"], environment: ["SIMSLIM_BOOT_TIMEOUT": "nope"])
    XCTAssertEqual(result.status, 1, "a bad environment value is an error too")
  }

  func testUnknownFlagAndArgumentCountErrors() {
    XCTAssertEqual(
      runCLI(["list", "--nope"]).stderr, "simslim: flag provided but not defined: -nope\n")
    XCTAssertEqual(runCLI(["list", "x"]).stderr, "simslim: list takes no arguments\n")
    XCTAssertEqual(
      runCLI(["status"]).stderr,
      "simslim: expected exactly one simulator UDID (see `simslim list`)\n")
    XCTAssertEqual(
      runCLI(["status", "a", "b"]).stderr,
      "simslim: expected exactly one simulator UDID (see `simslim list`)\n")
    XCTAssertEqual(
      runCLI(["profiles", "a", "b"]).stderr,
      "simslim: profiles takes at most one category ID (see `simslim profiles`)\n")
  }
}

final class ListCommandTests: XCTestCase {
  func testHumanOutputIsSortedAndShowsSlimStatus() {
    let result = runCLI(["list"], host: standardHost())
    XCTAssertEqual(result.status, 0)
    let lines = result.stdout.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 3)
    // iOS first, newest version first: 27.2 (iPad Air, iPhone 17 by name) then 18.4.
    XCTAssertEqual(
      lines[0], "\(shutdownUDID)  \(padRight("iPad Air", 22)) \(padRight("iOS 27.2", 14)) shutdown")
    XCTAssertEqual(
      lines[1],
      "\(bootedUDID)  \(padRight("iPhone 17", 22)) \(padRight("iOS 27.2", 14)) booted · 100/173 slim"
    )
    XCTAssertEqual(
      lines[2],
      "\(oldUDID)  \(padRight("iPhone 16", 22)) \(padRight("iOS 18.4", 14)) booted · 0/173 slim")
  }

  func testBootedFilter() {
    let result = runCLI(["list", "--booted"], host: standardHost())
    XCTAssertEqual(result.stdout.split(separator: "\n").count, 2)
    XCTAssertFalse(result.stdout.contains(shutdownUDID))
  }

  func testShutdownDevicesAreNeverSpawnedInto() {
    let host = standardHost()
    _ = runCLI(["list"], host: host)
    let spawned = host.calls.filter { $0.arguments.contains("spawn") }.compactMap {
      $0.arguments[safe: 2]
    }
    XCTAssertFalse(spawned.contains(shutdownUDID))
    XCTAssertEqual(Set(spawned), [bootedUDID, oldUDID])
  }

  func testLongNamesAreTruncatedInHumanOutput() {
    let host = FakeHost(devices: [.init(udid: "A", name: String(repeating: "x", count: 40))])
    let result = runCLI(["list"], host: host)
    XCTAssertTrue(result.stdout.contains(String(repeating: "x", count: 21) + "…"))
    XCTAssertFalse(result.stdout.contains(String(repeating: "x", count: 22)))
  }

  func testAStatusFailureDoesNotFailTheListing() throws {
    let host = standardHost()
    host.queueSpawnResults(
      udid: bootedUDID,
      Array(repeating: CommandResult(status: 2, stderr: Data("denied".utf8)), count: 1))
    let human = runCLI(["list"], host: host)
    XCTAssertEqual(human.status, 0)
    XCTAssertTrue(
      human.stdout.contains("\(padRight("iOS 27.2", 14)) booted\n"),
      "tag falls back to plain booted")

    let jsonHost = standardHost()
    jsonHost.queueSpawnResults(
      udid: bootedUDID, [CommandResult(status: 2, stderr: Data("denied".utf8))])
    let json = runCLI(["list", "--json"], host: jsonHost)
    let rows = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as? [[String: Any]])
    let row = try XCTUnwrap(rows.first { $0["udid"] as? String == bootedUDID })
    XCTAssertTrue((row["statusError"] as? String ?? "").contains("denied"))
    XCTAssertNil(row["managedDisabled"])
  }

  func testJSONShape() throws {
    let result = runCLI(["list", "--json"], host: standardHost())
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.stdout.hasSuffix("\n"))
    let rows = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [[String: Any]])
    XCTAssertEqual(rows.count, 3)

    let booted = try XCTUnwrap(rows.first { $0["udid"] as? String == bootedUDID })
    XCTAssertEqual(booted["managedDisabled"] as? Int, 100)
    XCTAssertEqual(booted["managedTotal"] as? Int, 173)
    XCTAssertEqual(booted["platform"] as? String, "iOS")
    XCTAssertEqual(booted["osVersion"] as? String, "27.2")
    XCTAssertEqual(booted["set"] as? String, "default")
    let memory = try XCTUnwrap(booted["memory"] as? [String: Any])
    XCTAssertEqual(memory["processes"] as? Int, 2)
    XCTAssertEqual(memory["bytes"] as? Int, 30 * 1_048_576)
    XCTAssertNil(booted["dataPath"], "internal fields never leak")
    XCTAssertNil(booted["runtimeID"])

    let shutdown = try XCTUnwrap(rows.first { $0["udid"] as? String == shutdownUDID })
    XCTAssertNil(shutdown["managedDisabled"], "unknown while shut down")
    XCTAssertNil(shutdown["memory"])
    XCTAssertEqual(shutdown["managedTotal"] as? Int, 173)
  }

  func testJSONOfAnEmptyListIsAnEmptyArray() {
    XCTAssertEqual(runCLI(["list", "--json"], host: FakeHost()).stdout, "[\n\n]\n")
  }

  func testJSONMeasuresAllBootedDevicesWithOneSnapshot() {
    let host = standardHost()
    _ = runCLI(["list", "--json"], host: host)
    XCTAssertEqual(host.calls.filter { $0.executable == .ps }.count, 1)
    XCTAssertEqual(host.calls.filter { $0.executable == .top }.count, 1)
  }

  func testHumanListDoesNotMeasureMemory() {
    let host = standardHost()
    _ = runCLI(["list"], host: host)
    XCTAssertFalse(host.calls.contains { $0.executable == .ps || $0.executable == .top })
  }

  func testListFailureIsReported() {
    let host = FakeHost()
    host.listFailure = "CoreSimulator is down"
    let result = runCLI(["list"], host: host)
    XCTAssertEqual(result.status, 1)
    XCTAssertEqual(result.stderr, "simslim: simctl list: exit status 1: CoreSimulator is down\n")
  }
}

final class ProfilesCommandTests: XCTestCase {
  func testOverview() {
    let result = runCLI(["profiles"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.stdout.hasPrefix("widgets        Widgets & Wallpaper\n"))
    XCTAssertTrue(
      result.stdout.contains("               4 daemons · ~675 MB idle footprint when enabled\n"))
    XCTAssertTrue(
      result.stdout.contains(
        "               Always on: com.apple.assistantd — Hosts the dictation service; without it the system Spotlight app leaks memory.\n"
      ))
    XCTAssertTrue(
      result.stdout.contains(
        "\n173 daemons across 16 categories. Core workflow and deadlock-prone daemons are never disabled.\n"
      ))
  }

  func testOneCategory() {
    let result = runCLI(["profiles", "search"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(result.stdout.contains("search         Spotlight & Search\n"))
    XCTAssertTrue(
      result.stdout.contains("               5 daemons · ~50 MB idle footprint when enabled\n"))
    XCTAssertTrue(result.stdout.contains("\nDaemons:\n"))
    XCTAssertTrue(result.stdout.contains("  \(padRight("com.apple.searchd", 44)) "))
  }

  func testAlwaysEnabledLinesAppearInACategoryListing() {
    XCTAssertTrue(
      runCLI(["profiles", "siri"]).stdout.contains(
        "  \(padRight("com.apple.assistantd", 44)) Always on — Hosts the dictation service"))
  }

  func testUnknownCategory() {
    let result = runCLI(["profiles", "nope"])
    XCTAssertEqual(result.status, 1)
    XCTAssertEqual(result.stderr, "simslim: unknown category \"nope\" (see `simslim profiles`)\n")
  }

  func testJSON() throws {
    let all = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(runCLI(["profiles", "--json"]).stdout.utf8))
        as? [[String: Any]])
    XCTAssertEqual(all.count, 16)
    XCTAssertEqual(all.compactMap { $0["id"] as? String }.first, "widgets")

    let one = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(runCLI(["profiles", "siri", "--json"]).stdout.utf8))
        as? [String: Any])
    XCTAssertEqual(one["id"] as? String, "siri")
    XCTAssertNotNil(one["alwaysEnabled"])
  }
}

final class StatusCommandTests: XCTestCase {
  func testHumanStatus() {
    let result = runCLI(["status", bootedUDID], host: standardHost())
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(
      result.stdout, "\(bootedUDID): 100/173 managed launchd labels disabled (partially slim)\n")
  }

  func testStockStatus() {
    let result = runCLI(["status", oldUDID], host: standardHost())
    XCTAssertEqual(result.stdout, "\(oldUDID): 0/173 managed launchd labels disabled (stock)\n")
  }

  func testSlimStatusOnANonPersistentRuntimeWarns() {
    let host = standardHost()
    host.disabled[oldUDID] = Profile().desired()  // iOS 18.4 cannot persist overrides
    let result = runCLI(["status", oldUDID], host: host)
    XCTAssertTrue(result.stdout.contains("(slim)\n"))
    XCTAssertTrue(
      result.stdout.contains(
        "  This runtime cannot persist launchd overrides: the state reverts to stock at the next reboot.\n"
      ))
  }

  func testStatusOfAShutdownSimulatorFails() {
    let result = runCLI(["status", shutdownUDID], host: standardHost())
    XCTAssertEqual(result.status, 1)
    XCTAssertEqual(
      result.stderr, "simslim: simulator must be booted to read its state (it is Shutdown)\n")
  }

  func testUnknownUDID() {
    let result = runCLI(["status", "nope"], host: standardHost())
    XCTAssertEqual(result.stderr, "simslim: no simulator with udid nope\n")
  }

  func testDropped() {
    let host = standardHost()
    host.disabled[bootedUDID] = ["com.apple.searchd", "com.apple.PosterBoard"]
    let result = runCLI(["status", bootedUDID, "--dropped"], host: host)
    XCTAssertTrue(
      result.stdout.contains("  widgets        Widgets & Wallpaper — Home and Lock Screen widgets"))
    XCTAssertTrue(result.stdout.contains("    com.apple.PosterBoard\n"))
    XCTAssertTrue(result.stdout.contains("  search         Spotlight & Search — "))

    host.disabled[bootedUDID] = []
    XCTAssertTrue(
      runCLI(["status", bootedUDID, "--dropped"], host: host).stdout.contains(
        "  Nothing dropped; every managed launchd label is enabled.\n"))
  }

  func testJSON() throws {
    let result = runCLI(["status", bootedUDID, "--json"], host: standardHost())
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys), ["managedDisabled", "managedTotal", "booted", "persistent", "verdict"])
    XCTAssertEqual(object["verdict"] as? String, "partially slim")
    XCTAssertEqual(object["managedDisabled"] as? Int, 100)

    let dropped = runCLI(["status", bootedUDID, "--json", "--dropped"], host: standardHost())
    let withDropped = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(dropped.stdout.utf8)) as? [String: Any])
    XCTAssertNotNil(withDropped["dropped"])
  }
}

final class VerifyCommandTests: XCTestCase {
  private func host(disabled: Set<String>) -> FakeHost {
    let host = standardHost()
    host.disabled[bootedUDID] = disabled
    return host
  }

  func testMatchExitsZero() {
    let result = runCLI(["verify", bootedUDID], host: host(disabled: Profile().desired()))
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(
      result.stdout,
      "\(bootedUDID) matches the profile: all expected disable overrides are applied.\n")
  }

  func testDriftExitsOneAndListsIt() {
    var disabled = Profile().desired()
    disabled.remove("com.apple.apsd")
    disabled.insert("com.apple.sharingd")  // managed, disabled beyond the profile
    disabled.insert("com.apple.unmanaged")  // never drift
    let result = runCLI(["verify", bootedUDID], host: host(disabled: disabled))
    XCTAssertEqual(result.status, 1)
    XCTAssertEqual(result.stderr, "")
    XCTAssertTrue(
      result.stdout.hasPrefix("\(bootedUDID) does not match the profile (1 missing, 1 extra):\n"))
    XCTAssertTrue(
      result.stdout.contains("  missing com.apple.apsd (should be disabled, is enabled)\n"))
    XCTAssertTrue(
      result.stdout.contains("  extra   com.apple.sharingd (disabled beyond the profile)\n"))
    XCTAssertFalse(result.stdout.contains("unmanaged"))
    XCTAssertTrue(result.stdout.hasSuffix("Re-run `simslim on` with the same profile to repair.\n"))
  }

  func testExceptAndKeepFlagsDefineTheProfile() {
    let profile = Profile(exceptCategories: ["search"], keep: ["com.apple.apsd"])
    let ok = runCLI(
      ["verify", bootedUDID, "--except", "search", "--keep", "com.apple.apsd"],
      host: host(disabled: profile.desired()))
    XCTAssertEqual(ok.status, 0)

    // The same device no longer matches the default (full) profile.
    XCTAssertEqual(
      runCLI(["verify", bootedUDID], host: host(disabled: profile.desired())).status, 1)
  }

  func testProfileFileCannotBeCombinedWithFlags() {
    let result = runCLI(
      ["verify", bootedUDID, "--profile", "x.json", "--except", "search"], host: standardHost())
    XCTAssertEqual(result.stderr, "simslim: --profile cannot be combined with --except or --keep\n")
    XCTAssertEqual(result.status, 1)
  }

  func testUnknownCategoryIsRejectedBeforeAnythingRuns() {
    let host = standardHost()
    let result = runCLI(["verify", bootedUDID, "--except", "nope"], host: host)
    XCTAssertEqual(result.status, 1)
    XCTAssertTrue(result.stderr.contains("unknown category \"nope\""))
    XCTAssertTrue(host.calls.isEmpty || !host.calls.contains { $0.arguments.contains("spawn") })
  }

  func testJSON() throws {
    var disabled = Profile().desired()
    disabled.remove("com.apple.apsd")
    let result = runCLI(["verify", bootedUDID, "--json"], host: host(disabled: disabled))
    XCTAssertEqual(result.status, 1, "JSON output still signals drift through the exit status")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(object["ok"] as? Bool, false)
    XCTAssertEqual(object["missing"] as? [String], ["com.apple.apsd"])
    XCTAssertNil(object["extra"])
  }
}

final class DoctorCommandTests: XCTestCase {
  func testList() {
    let result = runCLI(["doctor", "--list"])
    XCTAssertEqual(result.status, 0)
    XCTAssertTrue(
      result.stdout.hasPrefix(
        "\(padRight("push", 16)) \(padRight("Push notifications", 38)) com.apple.apsd\n"))
    XCTAssertEqual(result.stdout.split(separator: "\n").count, Catalog.features.count)
    XCTAssertEqual(
      runCLI(["doctor", "--list", "x"]).stderr, "simslim: doctor --list takes no arguments\n")
  }

  func testRequiresIsMandatory() {
    let result = runCLI(["doctor", bootedUDID], host: standardHost())
    XCTAssertEqual(
      result.stderr,
      "simslim: doctor needs at least one feature via --requires (see `simslim doctor --list`)\n")
    XCTAssertEqual(result.status, 1)
  }

  func testUnknownFeatureFailsLoudly() {
    let result = runCLI(["doctor", bootedUDID, "--requires", "push,nope"], host: standardHost())
    XCTAssertEqual(
      result.stderr, "simslim: unknown feature \"nope\" (see `simslim doctor --list`)\n")
  }

  func testHealthyAndBroken() {
    let healthy = standardHost()
    healthy.disabled[bootedUDID] = []
    let ok = runCLI(["doctor", bootedUDID, "--requires", "push,storekit"], host: healthy)
    XCTAssertEqual(ok.status, 0)
    XCTAssertEqual(
      ok.stdout, "\(bootedUDID): 2/2 required features OK\n  ok    push\n  ok    storekit\n")

    let broken = standardHost()
    broken.disabled[bootedUDID] = ["com.apple.storekitd", "com.apple.passd"]
    let bad = runCLI(["doctor", bootedUDID, "--requires", "push,storekit"], host: broken)
    XCTAssertEqual(bad.status, 1)
    XCTAssertTrue(bad.stdout.hasPrefix("\(bootedUDID): 1/2 required features OK\n  ok    push\n"))
    XCTAssertTrue(
      bad.stdout.contains("  BROKEN storekit — com.apple.storekitd, com.apple.passd disabled\n"))
  }

  func testAFullSlimProfileBreaksPushWhichIsWhyDoctorExists() {
    let host = standardHost()
    host.disabled[bootedUDID] = Profile().desired()
    XCTAssertEqual(runCLI(["doctor", bootedUDID, "--requires", "push"], host: host).status, 1)
    host.disabled[bootedUDID] = Profile(exceptCategories: ["store"]).desired()
    XCTAssertEqual(runCLI(["doctor", bootedUDID, "--requires", "push"], host: host).status, 0)
  }

  func testJSON() throws {
    let host = standardHost()
    host.disabled[bootedUDID] = ["com.apple.apsd"]
    let result = runCLI(["doctor", bootedUDID, "--requires", "push", "--json"], host: host)
    XCTAssertEqual(result.status, 1)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(object["udid"] as? String, bootedUDID)
    XCTAssertEqual(object["ok"] as? Bool, false)
  }
}

final class MeasureCommandTests: XCTestCase {
  func testHuman() {
    let result = runCLI(["measure", bootedUDID], host: standardHost())
    XCTAssertEqual(result.status, 0)
    XCTAssertEqual(
      result.stdout, "\(bootedUDID): 2 processes, 30 MB memory footprint (phys_footprint)\n")
  }

  func testJSON() throws {
    let result = runCLI(["measure", bootedUDID, "--json"], host: standardHost())
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
    XCTAssertEqual(object["processes"] as? Int, 2)
    XCTAssertEqual(object["bytes"] as? Int, 30 * 1_048_576)
    XCTAssertEqual(object["cpu"] as? Double, 3.0)
  }

  func testNotBooted() {
    let result = runCLI(["measure", shutdownUDID], host: standardHost())
    XCTAssertEqual(result.status, 1)
    XCTAssertEqual(
      result.stderr, "simslim: simulator \(shutdownUDID) does not appear to be booted\n")
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
