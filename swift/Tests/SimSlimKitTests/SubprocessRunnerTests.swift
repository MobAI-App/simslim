import XCTest

@testable import SimSlimKit

/// Behavior of the real process runner, using harmless system tools mapped over
/// the closed Executable list (only possible from tests, via `resolve`).
final class SubprocessRunnerTests: XCTestCase {
  private func runner(
    _ path: String, waitDelay: TimeInterval = 5
  ) -> SystemCommandRunner {
    SystemCommandRunner(waitDelay: waitDelay, resolve: { _ in path })
  }

  func testCapturesStdoutStderrAndStatusSeparately() throws {
    let result = try runner("/bin/sh").run(
      .xcrun, ["-c", "echo out; echo err 1>&2; exit 3"])
    XCTAssertEqual(result.status, 3)
    XCTAssertEqual(result.stdoutText, "out\n")
    XCTAssertEqual(result.stderrText, "err\n")
    XCTAssertEqual(result.combinedText, "out\nerr")
    XCTAssertFalse(result.timedOut)
    XCTAssertFalse(result.succeeded)
  }

  func testLargeOutputDoesNotDeadlock() throws {
    // Far more than a pipe buffer on both streams.
    let script =
      "head -c 3000000 /dev/zero | tr '\\0' a; head -c 3000000 /dev/zero | tr '\\0' b 1>&2"
    let result = try runner("/bin/sh").run(.xcrun, ["-c", script], timeout: 30)
    XCTAssertEqual(result.stdout.count, 3_000_000)
    XCTAssertEqual(result.stderr.count, 3_000_000)
    XCTAssertTrue(result.succeeded)
  }

  func testTimeoutKillsTheProcess() throws {
    let start = Date()
    let result = try runner("/bin/sleep").run(.xcrun, ["30"], timeout: 0.3)
    XCTAssertTrue(result.timedOut)
    XCTAssertFalse(result.succeeded)
    XCTAssertLessThan(Date().timeIntervalSince(start), 5, "the runner waited for the sleep")
    XCTAssertLessThan(result.status, 0, "a killed process reports the negated signal")
  }

  func testFastProcessIsNotReportedAsTimedOut() throws {
    let result = try runner("/bin/sh").run(.xcrun, ["-c", "exit 0"], timeout: 30)
    XCTAssertTrue(result.succeeded)
    XCTAssertFalse(result.timedOut)
  }

  func testPipeHeldOpenByGrandchildIsAbandonedAfterWaitDelay() throws {
    // The shell exits at once but its background child keeps stdout open for 5s,
    // like the simctl child a killed xcrun leaves behind. Without the wait delay
    // this call would block for those 5s.
    let start = Date()
    let result = try runner("/bin/sh", waitDelay: 0.4).run(
      .xcrun, ["-c", "sleep 5 & echo out"], timeout: 30)
    XCTAssertEqual(result.stdoutText, "out\n")
    XCTAssertTrue(result.succeeded)
    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
  }

  func testMissingExecutableThrowsAReadableError() {
    XCTAssertThrowsError(try runner("/nonexistent/simslim-tool").run(.xcrun, [])) { error in
      XCTAssertTrue(
        (error as? SimSlimError)?.message.hasPrefix("cannot run /nonexistent/simslim-tool") == true,
        "\(error)")
    }
  }

  func testStdinIsClosed() throws {
    // A child that reads stdin must see EOF immediately, not hang on our terminal.
    let result = try runner("/bin/cat").run(.xcrun, [], timeout: 10)
    XCTAssertTrue(result.succeeded)
    XCTAssertTrue(result.stdout.isEmpty)
  }
}
