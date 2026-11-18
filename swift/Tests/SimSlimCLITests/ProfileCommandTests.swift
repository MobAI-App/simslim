// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit
import TestSupport
import XCTest

@testable import SimSlimCLI

private final class Script: @unchecked Sendable {
  var lines: [String]
  var keys: [TopKey]
  var rawEntered = 0
  var restored = 0
  init(lines: [String], keys: [TopKey]) {
    self.lines = lines
    self.keys = keys
  }
  var input: WizardInput {
    WizardInput(
      readLine: { _ in self.lines.isEmpty ? nil : self.lines.removeFirst() },
      enterRaw: {
        self.rawEntered += 1
        return (24, { self.restored += 1 })
      },
      nextKey: { self.keys.isEmpty ? nil : self.keys.removeFirst() })
  }
}

private func runProfile(
  _ arguments: [String], lines: [String] = ["", ""], keys: [TopKey], interactive: Bool = true
) -> (CLIResult, Script) {
  let script = Script(lines: lines, keys: keys)
  let out = Buffer()
  let err = Buffer()
  var cli = CLI(
    version: "t", runner: FakeHost(), isInteractive: { interactive },
    stdout: { out.append($0) }, stderr: { err.append($0) })
  cli.wizardInput = script.input
  let status = cli.run(["profile"] + arguments)
  return (CLIResult(status: status, stdout: out.value, stderr: err.value), script)
}

private func scratch() -> String {
  let dir = NSTemporaryDirectory() + "simslim-profile-\(UUID().uuidString)"
  try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  return dir
}

final class ProfileCommandTests: XCTestCase {
  private let first = Catalog.categories[0]

  func testKeepingAFeatureAndADaemonPrintsTheProfile() {
    let second = Catalog.categories[1]
    let (r, script) = runProfile(
      [], lines: ["  Team  ", " for CI "],
      keys: [.character(" "), .down, .right, .character(" "), .left, .enter])
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(
      r.stdout,
      "{\n  \"name\": \"Team\",\n  \"description\": \"for CI\",\n  \"except\": [\n    \"\(first.id)\"\n  ],\n  \"keep\": [\n    \"\(second.labels[0])\"\n  ]\n}\n"
    )
    XCTAssertTrue(
      r.stderr.contains(
        "Keeping 1 feature(s) fully enabled and 1 individual daemon(s); slimming the rest."))
    XCTAssertEqual(script.rawEntered, 1)
    XCTAssertEqual(script.restored, 1, "the terminal is always restored")
  }

  func testCancelWritesNothingAndSucceeds() {
    for key in [TopKey.ctrlC, .character("q"), .character("Q")] {
      let (r, script) = runProfile([], keys: [.character(" "), key])
      XCTAssertEqual(r.status, 0)
      XCTAssertEqual(r.stdout, "")
      XCTAssertTrue(r.stderr.hasSuffix("Cancelled; no profile written.\n"))
      XCTAssertEqual(script.restored, 1)
    }
  }

  func testEndOfInputCancels() {
    let (r, script) = runProfile([], keys: [.character("a")])
    XCTAssertEqual(r.status, 0)
    XCTAssertEqual(r.stdout, "")
    XCTAssertTrue(r.stderr.hasSuffix("Cancelled; no profile written.\n"))
    XCTAssertEqual(script.restored, 1)
  }

  func testCtrlCInsideTheDaemonListCancelsEverything() {
    let (r, _) = runProfile([], keys: [.right, .character(" "), .ctrlC, .left, .enter])
    XCTAssertEqual(r.stdout, "")
    XCTAssertTrue(r.stderr.hasSuffix("Cancelled; no profile written.\n"))
  }

  func testAllThenNone() {
    let (all, _) = runProfile([], keys: [.character("a"), .enter])
    XCTAssertTrue(all.stdout.contains("\"\(Catalog.categories.last!.id)\""))
    let (none, _) = runProfile([], keys: [.character("a"), .character("n"), .enter])
    XCTAssertEqual(none.stdout, "{}\n")
  }

  func testKeptDaemonsInsideAKeptFeatureAreDropped() {
    // Keep one daemon of the first feature, then keep the whole feature.
    let (r, _) = runProfile(
      [], keys: [.right, .character(" "), .left, .character(" "), .enter])
    XCTAssertTrue(r.stdout.contains("\"except\""))
    XCTAssertFalse(r.stdout.contains("\"keep\""), r.stdout)
  }

  func testADaemonAnotherKeptFeatureCoversIsDropped() throws {
    // A label that lives in two categories is redundant once either is kept whole.
    let cats = Catalog.categories
    var shared: (Int, Int, String)?
    outer: for (i, a) in cats.enumerated() {
      for (j, b) in cats.enumerated() where j > i {
        if let l = a.labels.first(where: { b.labels.contains($0) }) {
          shared = (i, j, l)
          break outer
        }
      }
    }
    let (_, j, label) = try XCTUnwrap(shared)
    var model = WizardModel()
    model.keep.insert(label)
    model.except.insert(cats[j].id)
    XCTAssertFalse(model.selection().keep.contains(label))
    model.except = []
    let kept = model.selection().keep
    XCTAssertEqual(kept.filter { $0 == label }.count, 1, "listed once even when shared")
  }

  func testScrollingKeepsTheCursorVisible() {
    var model = WizardModel(termRows: 8)
    for _ in 0..<(Catalog.categories.count - 1) { model.key(.down) }
    XCTAssertEqual(model.cursor, Catalog.categories.count - 1)
    XCTAssertTrue(model.frame().contains("❯ "))
    XCTAssertTrue(model.frame().contains("↑more"))
    XCTAssertFalse(model.frame().contains("↓more"))
    model.key(.down)
    XCTAssertEqual(model.cursor, Catalog.categories.count - 1, "the cursor stops at the end")
    for _ in 0..<(Catalog.categories.count + 3) { model.key(.up) }
    XCTAssertEqual(model.cursor, 0)
    XCTAssertEqual(model.top, 0)
    XCTAssertTrue(model.frame().contains("↓more"))
  }

  func testMarkersShowKeptAndPartlyKept() {
    var model = WizardModel()
    model.key(.character(" "))
    model.key(.down)
    model.key(.right)
    model.key(.character(" "))
    model.key(.left)
    let rows = model.rows()
    XCTAssertTrue(rows[0].hasPrefix("[x] "))
    XCTAssertTrue(rows[1].hasPrefix("[~] "))
    XCTAssertTrue(rows[1].hasSuffix("(1 kept)"))
    XCTAssertTrue(rows[2].hasPrefix("[ ] "))
    XCTAssertEqual(model.cursor, 1, "going back lands on the feature that was open")
  }

  func testDaemonAllAndNoneStayInsideTheFeature() {
    var model = WizardModel()
    model.key(.right)
    model.key(.character("a"))
    XCTAssertEqual(model.keep, Set(Catalog.categories[0].labels))
    model.key(.character("n"))
    XCTAssertTrue(model.keep.isEmpty)
  }

  func testDaemonRowsFitTheScreenWidth() {
    var model = WizardModel()
    for index in Catalog.categories.indices {
      model.screen = .daemons(index)
      for row in model.rows() { XCTAssertLessThanOrEqual(row.unicodeScalars.count, 76) }
    }
  }

  func testWritesAFileAndRefusesToOverwriteIt() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/mine.json"
    let (r, _) = runProfile([path], keys: [.character(" "), .enter])
    XCTAssertEqual(r.status, 0, r.stderr)
    XCTAssertEqual(r.stdout, "")
    XCTAssertTrue(
      r.stderr.hasSuffix("Wrote \(path). Apply it with `simslim on <udid> --profile \(path)`.\n"))
    let text = try String(contentsOfFile: path, encoding: .utf8)
    XCTAssertTrue(text.contains("\"except\""))
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o644)

    let (again, script) = runProfile([path], keys: [.enter])
    XCTAssertEqual(again.status, 1)
    XCTAssertEqual(again.stderr, "simslim: refusing to overwrite \(path)\n")
    XCTAssertEqual(script.rawEntered, 0, "refused before any prompt")
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text)
  }

  func testADirectoryGetsANamedFileAndAnExistingOneIsPrintedInstead() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let (r, _) = runProfile([dir], lines: ["Team CI", ""], keys: [.character(" "), .enter])
    XCTAssertEqual(r.status, 0, r.stderr)
    let file = dir + "/team-ci.json"
    XCTAssertTrue(FileManager.default.fileExists(atPath: file))

    let before = try String(contentsOfFile: file, encoding: .utf8)
    let (second, _) = runProfile([dir], lines: ["Team CI", ""], keys: [.character("a"), .enter])
    XCTAssertEqual(second.status, 1)
    XCTAssertEqual(
      second.stderr.split(separator: "\n").last.map(String.init),
      "simslim: \(file) already exists; printed the profile above instead of overwriting it")
    XCTAssertTrue(second.stdout.contains("\"except\""))
    XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), before)
  }

  func testASymlinkAtTheDestinationIsNotFollowed() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let target = dir + "/target.json"
    let link = dir + "/link.json"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
    let (r, _) = runProfile([link], keys: [.enter])
    XCTAssertEqual(r.status, 1)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: target), "nothing is written through a link")
  }

  func testNeedsATerminalAndAtMostOnePath() {
    let (piped, script) = runProfile([], keys: [.enter], interactive: false)
    XCTAssertEqual(piped.status, 1)
    XCTAssertEqual(piped.stderr, "simslim: profile is interactive; run it in a terminal\n")
    XCTAssertEqual(script.rawEntered, 0)
    let (many, _) = runProfile(["a", "b"], keys: [])
    XCTAssertEqual(many.stderr, "simslim: profile takes an optional output path\n")
  }

  func testTheProfileItWritesLoadsBack() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/p.json"
    let (r, _) = runProfile(
      [path], keys: [.character(" "), .down, .right, .character(" "), .left, .enter])
    XCTAssertEqual(r.status, 0, r.stderr)
    let profile = try loadSlimProfile(path: path)
    XCTAssertFalse(profile.desired().isEmpty)
  }
}
