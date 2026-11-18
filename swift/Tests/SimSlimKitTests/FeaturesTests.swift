import XCTest

@testable import SimSlimKit

/// Ports of features_test.go.
final class FeaturesTests: XCTestCase {
  func testFeatureLabelsAreManaged() {
    for feature in Catalog.features {
      XCTAssertFalse(feature.labels.isEmpty, "feature \(feature.id) has no labels")
      for label in feature.labels {
        XCTAssertTrue(
          Catalog.managedSet.contains(label),
          "feature \(feature.id) names unmanaged daemon \(label)")
      }
    }
  }

  func testFeatureIDsAreUniqueAndNamed() {
    var seen = Set<String>()
    for feature in Catalog.features {
      XCTAssertFalse(feature.id.isEmpty)
      XCTAssertFalse(feature.name.isEmpty, "feature \(feature.id) has no name")
      XCTAssertTrue(seen.insert(feature.id).inserted, "duplicate feature ID \(feature.id)")
    }
    XCTAssertFalse(seen.isEmpty)
  }

  func testResolveFeatures() throws {
    let got = try Catalog.resolveFeatures(["push", "storekit"])
    XCTAssertEqual(got.map(\.id), ["push", "storekit"])
    XCTAssertThrowsError(try Catalog.resolveFeatures(["push", "nope"])) { error in
      XCTAssertEqual(
        (error as? SimSlimError)?.message,
        "unknown feature \"nope\" (see `simslim doctor --list`)")
    }
  }

  func testGameCenterDiagnosesLegacyDisabledGamed() throws {
    let features = try Catalog.resolveFeatures(["game-center"])
    XCTAssertTrue(Catalog.diagnoseFeatures(features, disabled: []).ok)
    let report = Catalog.diagnoseFeatures(features, disabled: ["com.apple.gamed"])
    XCTAssertFalse(report.ok)
    XCTAssertEqual(report.features.first?.disabled, ["com.apple.gamed"])
  }

  func testWidgetsDiagnoseDisabledNavd() throws {
    let features = try Catalog.resolveFeatures(["widgets"])
    XCTAssertTrue(Catalog.diagnoseFeatures(features, disabled: []).ok)
    let report = Catalog.diagnoseFeatures(features, disabled: ["com.apple.navd"])
    XCTAssertFalse(report.ok)
    XCTAssertEqual(report.features.first?.disabled, ["com.apple.navd"])
  }

  func testFilesRecentsDiagnoseDisabledSearchd() throws {
    let features = try Catalog.resolveFeatures(["files-recents"])
    XCTAssertTrue(Catalog.diagnoseFeatures(features, disabled: ["com.apple.searchtoold"]).ok)
    let report = Catalog.diagnoseFeatures(features, disabled: ["com.apple.searchd"])
    XCTAssertFalse(report.ok)
    XCTAssertEqual(report.features.first?.disabled, ["com.apple.searchd"])
  }

  func testSlimProfileReportsMDMAndAppClipsUntilExcepted() throws {
    let features = try Catalog.resolveFeatures(["mdm", "app-clips"])
    XCTAssertFalse(
      Catalog.diagnoseFeatures(features, disabled: Profile().desired()).ok,
      "a full slim profile must break MDM and App Clips")
    let kept = Profile(exceptCategories: ["mdm", "other"])
    XCTAssertTrue(
      Catalog.diagnoseFeatures(features, disabled: kept.desired()).ok,
      "--except mdm,other must keep MDM and App Clips")
  }

  func testDiagnoseFeatures() throws {
    let features = try Catalog.resolveFeatures(["push", "storekit", "universal-links"])

    XCTAssertTrue(Catalog.diagnoseFeatures(features, disabled: []).ok, "healthy on a stock device")

    let report = Catalog.diagnoseFeatures(features, disabled: ["com.apple.storekitd"])
    XCTAssertFalse(report.ok)
    let byID = Dictionary(uniqueKeysWithValues: report.features.map { ($0.id, $0) })
    XCTAssertEqual(byID["storekit"]?.ok, false)
    XCTAssertEqual(byID["storekit"]?.disabled, ["com.apple.storekitd"])
    XCTAssertEqual(byID["push"]?.ok, true)
    XCTAssertEqual(byID["universal-links"]?.ok, true)

    let spotlight = try Catalog.resolveFeatures(["spotlight"])
    XCTAssertFalse(
      Catalog.diagnoseFeatures(spotlight, disabled: ["com.apple.searchtoold"]).ok,
      "any disabled backing daemon breaks a multi-daemon feature")
  }

  // MARK: - JSON contract

  func testDoctorOutputOmitsEmptyFields() throws {
    let features = try Catalog.resolveFeatures(["push"])
    let healthy = Catalog.diagnoseFeatures(features, disabled: [])
    let json = try jsonObject(healthy)
    XCTAssertEqual(Set(json.keys), ["ok", "features"], "empty udid is omitted")
    let status = try XCTUnwrap((json["features"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(status.keys), ["id", "name", "ok"], "empty disabled list is omitted")

    var broken = Catalog.diagnoseFeatures(features, disabled: ["com.apple.apsd"])
    broken.udid = "UDID-1"
    let brokenJSON = try jsonObject(broken)
    XCTAssertEqual(Set(brokenJSON.keys), ["udid", "ok", "features"])
    let brokenStatus = try XCTUnwrap((brokenJSON["features"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(brokenStatus.keys), ["id", "name", "ok", "disabled"])
  }

  func testDoctorOutputRoundTrips() throws {
    let features = try Catalog.resolveFeatures(["push", "storekit"])
    var report = Catalog.diagnoseFeatures(features, disabled: ["com.apple.storekitd"])
    report.udid = "UDID-2"
    let data = try JSONEncoder().encode(report)
    XCTAssertEqual(try JSONDecoder().decode(DoctorOutput.self, from: data), report)
  }

  private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}
