// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import SimSlimKit
import XCTest

@testable import SimSlimCLI

final class ArgumentsTests: XCTestCase {
  private let specs: [FlagSpec] = [
    .bool("json", onlyOnce: true), .bool("booted"), .string("except"), .string("set"),
  ]

  func testFlagsMayComeBeforeOrAfterPositionals() throws {
    let a = try parseArguments(["udid", "--except", "search", "--json"], specs: specs)
    let b = try parseArguments(["--json", "--except", "search", "udid"], specs: specs)
    for parsed in [a, b] {
      XCTAssertEqual(parsed.positionals, ["udid"])
      XCTAssertEqual(parsed.string("except"), "search")
      XCTAssertTrue(parsed.bool("json"))
    }
  }

  func testFlagForms() throws {
    let parsed = try parseArguments(["-json", "--except=a,b", "--set", "/x y"], specs: specs)
    XCTAssertTrue(parsed.bool("json"))
    XCTAssertEqual(parsed.string("except"), "a,b")
    XCTAssertEqual(parsed.string("set"), "/x y")
  }

  func testEmptyInlineValueIsKeptNotDropped() throws {
    let parsed = try parseArguments(["--except="], specs: specs)
    XCTAssertTrue(parsed.has("except"))
    XCTAssertEqual(parsed.string("except"), "")
  }

  func testBoolFlagNeverConsumesTheNextToken() throws {
    let parsed = try parseArguments(["--booted", "udid"], specs: specs)
    XCTAssertEqual(parsed.positionals, ["udid"])
    XCTAssertTrue(parsed.bool("booted"))
  }

  func testBoolFlagValues() throws {
    XCTAssertFalse(try parseArguments(["--booted=false"], specs: specs).bool("booted"))
    XCTAssertTrue(try parseArguments(["--booted=true"], specs: specs).bool("booted"))
    XCTAssertThrowsError(try parseArguments(["--booted=maybe"], specs: specs))
  }

  func testDoubleDashEndsFlagParsing() throws {
    let parsed = try parseArguments(["--json", "--", "--except", "-x"], specs: specs)
    XCTAssertEqual(parsed.positionals, ["--except", "-x"])
    XCTAssertTrue(parsed.bool("json"))
    XCTAssertFalse(parsed.has("except"))
  }

  func testLoneDashIsAPositional() throws {
    XCTAssertEqual(try parseArguments(["-"], specs: specs).positionals, ["-"])
  }

  func testStringFlagConsumesTheNextTokenEvenIfItLooksLikeAFlag() throws {
    XCTAssertEqual(
      try parseArguments(["--except", "--json"], specs: specs).string("except"), "--json")
  }

  func testErrors() {
    func message(_ tokens: [String]) -> String? {
      do {
        _ = try parseArguments(tokens, specs: specs)
        return nil
      } catch { return (error as? SimSlimError)?.message }
    }
    XCTAssertEqual(message(["--nope"]), "flag provided but not defined: -nope")
    XCTAssertEqual(message(["--except"]), "flag needs an argument: --except")
    XCTAssertEqual(message(["--json", "--json"]), "flag --json can only be used once")
    XCTAssertNil(message(["--booted", "--booted"]), "only json is once-only")
  }

  func testLastStringValueWins() throws {
    XCTAssertEqual(
      try parseArguments(["--except", "a", "--except", "b"], specs: specs).string("except"), "b")
  }
}

final class DurationTests: XCTestCase {
  func testValidDurations() throws {
    let cases: [(String, TimeInterval)] = [
      ("10m", 600), ("90s", 90), ("1h", 3600), ("1h30m", 5400), ("1.5h", 5400), ("500ms", 0.5),
      ("2m30s", 150), ("0", 0), ("+5s", 5), ("-5s", -5), ("1us", 1e-6), ("1µs", 1e-6),
      ("1ns", 1e-9),
    ]
    for (text, seconds) in cases {
      XCTAssertEqual(try parseGoDuration(text), seconds, accuracy: 1e-9, text)
    }
  }

  func testInvalidDurations() {
    for text in [
      "", "abc", "10", "10x", "m10", "1h 30m", ".", "--5s", "5s5",
      "9999999999999999999s", String(repeating: "9", count: 400) + "s",
    ] {
      XCTAssertThrowsError(try parseGoDuration(text), "\"\(text)\"")
    }
    XCTAssertThrowsError(try parseGoDuration("10")) { error in
      XCTAssertEqual((error as? SimSlimError)?.message, "time: missing unit in duration \"10\"")
    }
    XCTAssertThrowsError(try parseGoDuration("10x")) { error in
      XCTAssertEqual(
        (error as? SimSlimError)?.message, "time: unknown unit \"x\" in duration \"10x\"")
    }
  }
}

final class FormatTests: XCTestCase {
  func testPadRightCountsScalarsLikeGo() {
    XCTAssertEqual(padRight("ab", 5), "ab   ")
    XCTAssertEqual(padRight("abcdef", 3), "abcdef", "never truncates")
    XCTAssertEqual(padRight("é", 3), "é  ")
  }

  func testTruncate() {
    XCTAssertEqual(truncate("short", 22), "short")
    XCTAssertEqual(truncate("abcdefghij", 5), "abcd…")
    XCTAssertEqual(truncate("abcdefghij", 1), "…")
    XCTAssertEqual(truncate("abcde", 5), "abcde")
  }

  func testHumanBytes() {
    XCTAssertEqual(humanBytes(0), "0 B")
    XCTAssertEqual(humanBytes(1023), "1023 B")
    XCTAssertEqual(humanBytes(1024), "1 KB")
    XCTAssertEqual(humanBytes(5 * 1_048_576), "5 MB")
    XCTAssertEqual(humanBytes(1_610_612_736), "1.50 GB")
  }
}
