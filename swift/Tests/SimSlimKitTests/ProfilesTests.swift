// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import XCTest

@testable import SimSlimKit

/// Ports of profiles_test.go. These encode the safety invariants of the tool:
/// what may ever be disabled, and that nothing outside the allowlist is touched.
final class ProfilesTests: XCTestCase {
  private let full = Profile()

  func testManagedExcludesForbidden() {
    for label in forbiddenLabels {
      XCTAssertFalse(
        Catalog.managedSet.contains(label),
        "forbidden daemon \(label) is in a category; it must never be managed")
    }
  }

  func testForbiddenListIsNotEmpty() {
    // Guards against the generator silently producing an empty list, which
    // would make testManagedExcludesForbidden vacuous.
    XCTAssertGreaterThanOrEqual(forbiddenLabels.count, 10)
    XCTAssertTrue(forbiddenLabels.contains("com.apple.nanoregistryd"))
  }

  func testFullProfileDoesNotClaimUnmanagedProcesses() {
    let desired = full.desired()
    for label in [
      "com.apple.routined", "com.apple.sharingd", "com.apple.locationd",
      "com.apple.eventkitsyncd", "com.apple.Spotlight", "com.apple.MercuryPoster",
      "com.apple.texttospeech.SiriAUSP",
    ] {
      XCTAssertFalse(desired.contains(label), "full profile claims live process \(label)")
    }
  }

  func testNoDuplicateLabelsWithinCategory() {
    for category in Catalog.categories {
      XCTAssertEqual(
        category.labels.count, Set(category.labels).count,
        "category \(category.id) lists a label twice")
    }
  }

  func testCategoryIDsAreUnique() {
    let ids = Catalog.categories.map(\.id)
    XCTAssertEqual(ids.count, Set(ids).count)
    XCTAssertFalse(ids.isEmpty)
  }

  func testDesiredKeepsSharedLabelsOfExceptedCategories() {
    var owners: [String: [String]] = [:]
    for category in Catalog.categories {
      for label in category.labels { owners[label, default: []].append(category.id) }
    }
    var sharedSeen = false
    for (label, ids) in owners where ids.count >= 2 {
      sharedSeen = true
      for id in ids {
        let profile = Profile(exceptCategories: [id])
        XCTAssertFalse(
          profile.desired().contains(label),
          "--except \(id) should keep shared label \(label) enabled")
      }
    }
    XCTAssertTrue(sharedSeen, "expected at least one shared label (the AMS payment-sheet daemons)")
  }

  func testEveryServiceHasShortDescription() {
    var known = Set<String>()
    for category in Catalog.categories {
      XCTAssertEqual(
        category.serviceDescriptions.count, category.labels.count,
        "category \(category.id) label and description counts differ")
      for label in category.labels {
        known.insert(label)
        let description = category.serviceDescriptions[label] ?? ""
        XCTAssertFalse(
          description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          "service \(label) has no user-facing description")
        XCTAssertFalse(
          description.contains("\n") || description.contains("\r"),
          "service \(label) description must stay on one logical line")
        XCTAssertLessThanOrEqual(
          description.utf8.count, 90, "service \(label) description is too long")
      }
    }
    for label in serviceDescriptionByLabel.keys {
      XCTAssertTrue(known.contains(label), "description exists for unmanaged service \(label)")
    }
  }

  func testRequiredEnabledLabelsAreNeverSlimmed() {
    let desired = full.desired()
    var sawRequired = false
    for category in Catalog.categories {
      for service in category.alwaysEnabled {
        sawRequired = true
        XCTAssertFalse(
          Catalog.slimmableSet.contains(service.label) || desired.contains(service.label),
          "required daemon \(service.label) is included in a slim profile")
        XCTAssertTrue(
          Catalog.managedSet.contains(service.label),
          "required daemon \(service.label) is missing from the repair allowlist")
        XCTAssertFalse(service.reason.isEmpty, "\(service.label) has no user-facing reason")
      }
    }
    XCTAssertTrue(sawRequired)
  }

  func testDeltaRepairsRequiredEnabledLabels() {
    let current: Set<String> = ["com.apple.sharingd"]
    let result = delta(current: current, desired: full.desired(), managed: Catalog.managedSet)
    XCTAssertFalse(result.toDisable.isEmpty, "full profile should still disable slimmable labels")
    XCTAssertEqual(result.toEnable, ["com.apple.sharingd"])
  }

  func testGamedStaysEnabledForXCTest() throws {
    let label = "com.apple.gamed"
    let desired = full.desired()
    XCTAssertFalse(Catalog.slimmableSet.contains(label) || desired.contains(label))
    let apps = try XCTUnwrap(Catalog.category(id: "apps"))
    XCTAssertTrue(
      apps.alwaysEnabled.contains {
        $0.label == label && !$0.reason.trimmingCharacters(in: .whitespaces).isEmpty
      }, "apps must explain why gamed stays enabled")
    let repair = delta(current: [label], desired: desired, managed: Catalog.managedSet)
    XCTAssertEqual(repair.toEnable, [label])
    for other in ["com.apple.gamesaved", "com.apple.GameController.gamecontrollerd"] {
      XCTAssertTrue(
        desired.contains(other), "unrelated game service \(other) should stay slimmable")
    }
  }

  func testAssistantdStaysEnabledForSpotlight() throws {
    let label = "com.apple.assistantd"
    let desired = full.desired()
    XCTAssertFalse(Catalog.slimmableSet.contains(label) || desired.contains(label))
    let siri = try XCTUnwrap(Catalog.category(id: "siri"))
    XCTAssertTrue(
      siri.alwaysEnabled.contains {
        $0.label == label && !$0.reason.trimmingCharacters(in: .whitespaces).isEmpty
      }, "siri must explain why assistantd stays enabled")
    let repair = delta(current: [label], desired: desired, managed: Catalog.managedSet)
    XCTAssertEqual(repair.toEnable, [label])
    for other in [
      "com.apple.assistant_service", "com.apple.corespeechd", "com.apple.siriknowledged",
    ] {
      XCTAssertTrue(desired.contains(other), "other Siri service \(other) should stay slimmable")
    }
  }

  func testWidgetsKeepNavdForMapsWidget() {
    let label = "com.apple.navd"
    XCTAssertFalse(
      Profile(exceptCategories: ["widgets"]).desired().contains(label),
      "--except widgets must keep navd enabled: the Maps widget spins without it")
    XCTAssertTrue(
      full.desired().contains(label), "navd should stay slimmable when widgets are disabled")
  }

  func testCategoriesHaveUserImpactMetadata() {
    for category in Catalog.categories {
      XCTAssertFalse(category.downside.isEmpty, "category \(category.id) has no downside")
      XCTAssertGreaterThan(category.approxMemoryMB, 0, "category \(category.id) memory estimate")
    }
  }

  func testCategoryByID() {
    for category in Catalog.categories {
      XCTAssertEqual(Catalog.category(id: category.id)?.id, category.id)
    }
    XCTAssertNil(Catalog.category(id: "nope"))
  }

  func testDesiredHonorsKeep() {
    XCTAssertTrue(full.desired().contains("com.apple.apsd"))
    XCTAssertFalse(Profile(keep: ["com.apple.apsd"]).desired().contains("com.apple.apsd"))
  }

  // MARK: - Platform rules (Profile.desired(for:))

  func testWatchOSKeepsHomedEnabled() {
    let watch = Device(udid: "W", platform: "watchOS")
    XCTAssertTrue(full.desired().contains("com.apple.homed"))
    XCTAssertFalse(full.desired(for: watch).contains("com.apple.homed"))
    XCTAssertTrue(full.desired(for: watch).contains("com.apple.mobileassetd"))
  }

  func testVisionOSKeepsMobileassetdEnabled() {
    let vision = Device(udid: "V", platform: "visionOS")
    XCTAssertTrue(full.desired().contains("com.apple.mobileassetd"))
    XCTAssertFalse(full.desired(for: vision).contains("com.apple.mobileassetd"))
    XCTAssertTrue(full.desired(for: vision).contains("com.apple.homed"))
  }

  func testIOSAndEmptyPlatformGetTheFullCatalog() {
    for platform in ["", "iOS", "tvOS"] {
      let device = Device(udid: "D", platform: platform)
      XCTAssertEqual(full.desired(for: device), full.desired(), "platform \"\(platform)\"")
    }
  }

  // MARK: - delta

  func testDelta() {
    let managed: Set<String> = ["a", "b", "c"]
    struct Case {
      let name: String
      let current: Set<String>
      let desired: Set<String>
      let disable: [String]
      let enable: [String]
    }
    let cases = [
      Case(
        name: "enable all from stock", current: [], desired: ["a", "b", "c"],
        disable: ["a", "b", "c"], enable: []),
      Case(
        name: "restore all to stock", current: ["a", "b", "c"], desired: [], disable: [],
        enable: ["a", "b", "c"]),
      Case(
        name: "already in desired state", current: ["a", "b"], desired: ["a", "b"], disable: [],
        enable: []),
      Case(
        name: "profile edit adds and removes", current: ["a", "b"], desired: ["b", "c"],
        disable: ["c"], enable: ["a"]),
      Case(
        name: "unmanaged desired label is ignored", current: [], desired: ["x"], disable: [],
        enable: []),
      Case(
        name: "unmanaged disabled label is left alone", current: ["x"], desired: [], disable: [],
        enable: []),
    ]
    for tc in cases {
      let got = delta(current: tc.current, desired: tc.desired, managed: managed)
      XCTAssertEqual(got.toDisable, tc.disable, tc.name)
      XCTAssertEqual(got.toEnable, tc.enable, tc.name)
    }
  }

  func testDeltaNeverTouchesUnmanagedLabels() {
    // The central safety property, checked against the real allowlist: whatever
    // the device has disabled and whatever the profile asks for, delta only
    // ever names managed labels.
    let current: Set<String> = Set(forbiddenLabels).union(["com.apple.not-ours", "com.apple.apsd"])
    let desired = Set(forbiddenLabels).union(full.desired()).union(["com.apple.also-not-ours"])
    let result = delta(current: current, desired: desired, managed: Catalog.managedSet)
    for label in result.toDisable + result.toEnable {
      XCTAssertTrue(Catalog.managedSet.contains(label), "delta named unmanaged label \(label)")
    }
    for label in forbiddenLabels {
      XCTAssertFalse(result.toDisable.contains(label) || result.toEnable.contains(label))
    }
  }

  func testDeltaIsSorted() {
    let result = delta(current: [], desired: ["c", "a", "b"], managed: ["a", "b", "c"])
    XCTAssertEqual(result.toDisable, ["a", "b", "c"])
  }

  // MARK: - JSON contract with the SwiftUI app

  func testCategoryJSONKeys() throws {
    let siri = try XCTUnwrap(Catalog.category(id: "siri"))
    let search = try XCTUnwrap(Catalog.category(id: "search"))

    let siriJSON = try jsonObject(siri)
    XCTAssertEqual(
      Set(siriJSON.keys),
      [
        "id", "name", "description", "downside", "approxMemoryMB", "labels",
        "serviceDescriptions", "alwaysEnabled",
      ])
    // `omitempty`: a category with no always-enabled services omits the key.
    XCTAssertFalse(try jsonObject(search).keys.contains("alwaysEnabled"))

    let alwaysEnabled = try XCTUnwrap(siriJSON["alwaysEnabled"] as? [[String: Any]])
    XCTAssertEqual(Set(try XCTUnwrap(alwaysEnabled.first).keys), ["label", "reason"])
  }

  func testCategoryRoundTrips() throws {
    for category in Catalog.categories {
      let data = try JSONEncoder().encode(category)
      XCTAssertEqual(try JSONDecoder().decode(Category.self, from: data), category)
    }
  }

  func testDeviceJSONKeysExcludeInternalFields() throws {
    let device = Device(
      udid: "U", name: "N", state: "Booted", platform: "iOS", osVersion: "27.2", set: "default",
      dataPath: "/secret/path", runtimeID: "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
    XCTAssertEqual(
      Set(try jsonObject(device).keys), ["udid", "name", "state", "platform", "osVersion", "set"])
  }

  private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
