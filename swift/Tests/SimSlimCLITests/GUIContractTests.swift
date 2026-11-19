// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

/// `Models.swift` is the macOS app's own file (symlinked from gui/). Decoding the
/// Swift CLI's JSON with those exact types is the contract check: if an output
/// field is renamed, dropped or retyped, this fails instead of the app at runtime.
final class GUIContractTests: XCTestCase {
  private func decode<T: Decodable>(
    _ type: T.Type, _ arguments: [String], host: FakeHostFactory = .standard
  ) throws -> T {
    let result = runCLI(arguments, host: host.make())
    XCTAssertEqual(result.status, 0, result.stderr)
    return try JSONDecoder().decode(type, from: Data(result.stdout.utf8))
  }

  func testListDecodesAsTheAppsSimulatorDevice() throws {
    let devices = try decode([SimulatorDevice].self, ["list", "--json"])
    XCTAssertEqual(devices.count, 3)

    let booted = try XCTUnwrap(devices.first { $0.udid == bootedUDID })
    XCTAssertTrue(booted.isBooted)
    XCTAssertEqual(booted.name, "iPhone 17")
    XCTAssertEqual(booted.runtimeName, "iOS 27.2")
    XCTAssertEqual(booted.managedDisabled, 100)
    XCTAssertEqual(booted.managedTotal, 173)
    XCTAssertEqual(booted.memory?.processes, 2)
    XCTAssertEqual(booted.memory?.bytes, 30 * 1_048_576)
    XCTAssertNil(booted.statusError)

    let shutdown = try XCTUnwrap(devices.first { $0.udid == shutdownUDID })
    XCTAssertFalse(shutdown.isBooted)
    XCTAssertNil(shutdown.managedDisabled)
    XCTAssertNil(shutdown.memory)
  }

  func testProfilesDecodeAsTheAppsSlimCategory() throws {
    let categories = try decode([SlimCategory].self, ["profiles", "--json"])
    XCTAssertEqual(categories.count, 16)
    for category in categories {
      XCTAssertFalse(category.labels.isEmpty, category.id)
      XCTAssertGreaterThan(category.approxMemoryMB, 0, category.id)
      for label in category.labels {
        XCTAssertNotEqual(
          category.serviceDescription(for: label), "Apple background service.",
          "\(category.id): \(label) has no description, so the app would show its placeholder")
      }
    }
    let siri = try XCTUnwrap(categories.first { $0.id == "siri" })
    XCTAssertEqual(siri.alwaysEnabledServices.map(\.label), ["com.apple.assistantd"])
    XCTAssertEqual(categories.first { $0.id == "search" }?.alwaysEnabledServices.count, 0)
  }

  func testOneCategoryDecodes() throws {
    let category = try decode(SlimCategory.self, ["profiles", "apps", "--json"])
    XCTAssertEqual(category.id, "apps")
    XCTAssertEqual(category.alwaysEnabledServices.first?.label, "com.apple.gamed")
  }

  func testMeasureDecodesAsTheAppsMeasurement() throws {
    let measurement = try decode(SimulatorMeasurement.self, ["measure", bootedUDID, "--json"])
    XCTAssertEqual(measurement.processes, 2)
    XCTAssertEqual(measurement.bytes, 30 * 1_048_576)
  }

  func testBootAndShutdownDecodeAsTheAppsMutationResult() throws {
    let boot = try decode(SimulatorMutationResult.self, ["boot", "--json", shutdownUDID])
    XCTAssertEqual(boot.action, "boot")
    XCTAssertEqual(boot.udid, shutdownUDID)

    let down = try decode(SimulatorMutationResult.self, ["shutdown", "--json", bootedUDID])
    XCTAssertEqual(down.action, "shutdown")
    XCTAssertEqual(down.udid, bootedUDID)
  }

  /// The app reads stdout and stderr through one pipe, so anything on stderr
  /// under --json would corrupt the JSON it decodes.
  func testJSONCommandsTheAppCallsKeepStderrEmpty() {
    let calls: [[String]] = [
      ["list", "--json"], ["profiles", "--json"], ["measure", "--json", bootedUDID],
      ["boot", "--json", shutdownUDID], ["shutdown", "--json", bootedUDID],
      ["disk-categories", "--json"],
    ]
    for arguments in calls {
      let result = runCLI(arguments, host: FakeHostFactory.standard.make())
      XCTAssertEqual(result.status, 0, "\(arguments): \(result.stderr)")
      XCTAssertEqual(result.stderr, "", "\(arguments) wrote to stderr under --json")
    }
  }
}

/// Builds a fresh standard host per call (FakeHost is stateful).
struct FakeHostFactory {
  var make: () -> FakeHost
  static let standard = FakeHostFactory(make: standardHost)
}
