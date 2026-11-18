// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import XCTest

@testable import SimSlimKit

final class SubprocessTests: XCTestCase {
  func testEveryExecutablePathIsAbsolute() {
    for executable in Executable.allCases {
      XCTAssertTrue(executable.rawValue.hasPrefix("/"), "\(executable) must be an absolute path")
    }
  }

  func testEveryExecutableExistsOnThisMac() {
    for executable in Executable.allCases {
      XCTAssertTrue(
        FileManager.default.isExecutableFile(atPath: executable.rawValue),
        "\(executable.rawValue) is missing or not executable")
    }
  }

  func testSystemRunnerCapturesOutputAndStatus() throws {
    // plutil -help prints usage to stdout and exits 0.
    let ok = try SystemCommandRunner().run(.plutil, ["-help"])
    XCTAssertEqual(ok.status, 0)
    XCTAssertFalse(ok.stdoutText.isEmpty)

    // A missing file is a non-zero exit with a message, not a thrown error.
    let missing = try SystemCommandRunner().run(.plutil, ["-lint", "/nonexistent/simslim-test"])
    XCTAssertNotEqual(missing.status, 0)
    XCTAssertFalse((missing.stdoutText + missing.stderrText).isEmpty)
  }
}
