import XCTest

@testable import SimSlimKit

/// Ports of profile_file_test.go.
final class ProfileFileTests: XCTestCase {
  /// Writes `contents` to a fresh temporary file and returns its path.
  private func writeProfile(_ contents: String) throws -> String {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("simslim-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("profile.json")
    try Data(contents.utf8).write(to: url)
    return url.path
  }

  private func missingPath() -> String {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("simslim-absent-\(UUID().uuidString).json").path
  }

  func testLoadSlimProfile() throws {
    let path = try writeProfile(
      """
      {
        "name": "ci",
        "description": "UI test runs",
        "except": ["search", "store"],
        "keep": ["com.apple.apsd"]
      }
      """)
    let profile = try loadSlimProfile(path: path)
    XCTAssertEqual(profile.exceptCategories, ["search", "store"])
    XCTAssertEqual(profile.keep, ["com.apple.apsd"])
  }

  func testLoadSlimProfileMinimal() throws {
    let profile = try loadSlimProfile(path: try writeProfile("{}"))
    XCTAssertTrue(profile.exceptCategories.isEmpty)
    XCTAssertTrue(profile.keep.isEmpty)
  }

  func testNullDocumentIsTheEmptyProfile() throws {
    // Go decodes JSON null into the zero value.
    XCTAssertEqual(try loadSlimProfile(path: try writeProfile("null")), Profile())
  }

  func testLoadSlimProfileKeepsRequiredEnabledLabels() throws {
    let path = try writeProfile(#"{"keep": ["com.apple.gamed", "com.apple.sharingd"]}"#)
    let profile = try loadSlimProfile(path: path)
    for label in ["com.apple.gamed", "com.apple.sharingd"] {
      XCTAssertTrue(profile.keep.contains(label))
      XCTAssertFalse(
        profile.desired().contains(label), "must keep required service \(label) enabled")
    }
  }

  func testLoadSlimProfileTrimsAndSkipsBlankEntries() throws {
    let path = try writeProfile(
      #"{"except": [" search ", "", "  "], "keep": [" com.apple.apsd "]}"#)
    let profile = try loadSlimProfile(path: path)
    XCTAssertEqual(profile.exceptCategories, ["search"])
    XCTAssertEqual(profile.keep, ["com.apple.apsd"])
  }

  func testLoadSlimProfileRejects() throws {
    let cases: [(name: String, contents: String, messagePart: String)] = [
      ("unknown category", #"{"except": ["nope"]}"#, "unknown category \"nope\""),
      (
        "unknown keep label", #"{"keep": ["com.apple.does-not-exist"]}"#,
        "\"com.apple.does-not-exist\" is not a managed daemon"
      ),
      ("unknown field", #"{"disable": ["search"]}"#, "unknown field \"disable\""),
      ("malformed json", #"{"except": ["#, "parse profile"),
      ("wrong type for except", #"{"except": "search"}"#, "must be an array of strings"),
      ("wrong type for name", #"{"name": 5}"#, "must be a string"),
      ("array at top level", #"[]"#, "top level must be a JSON object"),
      ("empty file", "", "is empty; write {} for the default profile"),
      ("whitespace only", "  \n ", "is empty; write {} for the default profile"),
    ]
    for tc in cases {
      let path = try writeProfile(tc.contents)
      XCTAssertThrowsError(try loadSlimProfile(path: path), tc.name) { error in
        let message = (error as? SimSlimError)?.message ?? "\(error)"
        XCTAssertTrue(message.contains(tc.messagePart), "\(tc.name): got \"\(message)\"")
      }
    }
  }

  func testUnknownFieldMatchingIsCaseInsensitiveLikeGo() throws {
    let profile = try loadSlimProfile(path: try writeProfile(#"{"Except": ["search"]}"#))
    XCTAssertEqual(profile.exceptCategories, ["search"])
  }

  func testLoadSlimProfileMissingFile() {
    XCTAssertThrowsError(try loadSlimProfile(path: missingPath())) { error in
      let message = (error as? SimSlimError)?.message ?? ""
      XCTAssertTrue(message.hasPrefix("read profile "), message)
      XCTAssertTrue(message.contains("no such file"), message)
    }
  }

  func testBuildProfile() throws {
    let fromFlags = try buildProfile(profilePath: "", except: "search", keep: "com.apple.apsd")
    XCTAssertTrue(fromFlags.exceptCategories.contains("search"))
    XCTAssertTrue(fromFlags.keep.contains("com.apple.apsd"))

    XCTAssertThrowsError(try buildProfile(profilePath: "", except: "nope", keep: ""))

    let path = try writeProfile(#"{"except": ["search"]}"#)
    XCTAssertEqual(
      try buildProfile(profilePath: path, except: "", keep: "").exceptCategories, ["search"])

    XCTAssertThrowsError(try buildProfile(profilePath: "some.json", except: "search", keep: "")) {
      XCTAssertEqual(
        ($0 as? SimSlimError)?.message, "--profile cannot be combined with --except or --keep")
    }
    XCTAssertThrowsError(
      try buildProfile(profilePath: "some.json", except: "", keep: "com.apple.apsd"))
  }

  func testBuildProfileKeepFlagIsNotValidatedLikeGo() throws {
    // Go's --keep flag accepts any label (only profile files are validated);
    // delta() later ignores unmanaged labels, so this is safe. Ported as-is.
    let profile = try buildProfile(profilePath: "", except: "", keep: "com.apple.unknown")
    XCTAssertEqual(profile.keep, ["com.apple.unknown"])
  }

  func testSplitList() {
    XCTAssertEqual(splitList("a, b ,,c"), ["a", "b", "c"])
    XCTAssertEqual(splitList(""), [])
    XCTAssertEqual(splitList(" , "), [])
  }

  func testProfileFileName() {
    let cases: [(String, String)] = [
      ("ci", "ci.json"),
      ("UI Test Runs", "ui-test-runs.json"),
      ("", "profile.json"),
      ("  ", "profile.json"),
      ("prod.json", "prod.json"),
      ("a/b:c", "a-b-c.json"),
      ("--weird--", "weird.json"),
    ]
    for (name, want) in cases {
      XCTAssertEqual(profileFileName(name), want, "profileFileName(\"\(name)\")")
    }
  }

  // MARK: - marshalProfile: byte-for-byte what Go's json.MarshalIndent prints

  func testMarshalProfileFull() {
    let data = marshalProfile(
      SlimProfile(
        name: "ci", description: "UI test runs", except: ["search", "store"],
        keep: ["com.apple.apsd"]))
    XCTAssertEqual(
      String(decoding: data, as: UTF8.self),
      """
      {
        "name": "ci",
        "description": "UI test runs",
        "except": [
          "search",
          "store"
        ],
        "keep": [
          "com.apple.apsd"
        ]
      }

      """)
  }

  func testMarshalProfileEmptyAndPartial() {
    XCTAssertEqual(String(decoding: marshalProfile(SlimProfile()), as: UTF8.self), "{}\n")
    XCTAssertEqual(
      String(decoding: marshalProfile(SlimProfile(keep: ["com.apple.apsd"])), as: UTF8.self),
      "{\n  \"keep\": [\n    \"com.apple.apsd\"\n  ]\n}\n")
  }

  func testMarshalProfileEscapesLikeGo() {
    let data = marshalProfile(SlimProfile(name: "a<b>&\"q\"\\\n\u{2028}\u{01}"))
    XCTAssertEqual(
      String(decoding: data, as: UTF8.self),
      "{\n  \"name\": \"a\\u003cb\\u003e\\u0026\\\"q\\\"\\\\\\n\\u2028\\u0001\"\n}\n")
  }

  func testMarshalThenLoadRoundTrips() throws {
    let original = SlimProfile(
      name: "x & y", description: "d", except: ["search", "store"], keep: ["com.apple.apsd"])
    let path = try writeProfile(String(decoding: marshalProfile(original), as: UTF8.self))
    let parsed = try parseSlimProfile(try Data(contentsOf: URL(fileURLWithPath: path)), path: path)
    XCTAssertEqual(parsed, original)
  }
}
