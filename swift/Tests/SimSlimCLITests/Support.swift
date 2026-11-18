import Foundation
import SimSlimKit
import TestSupport

@testable import SimSlimCLI

struct CLIResult {
  var status: Int32
  var stdout: String
  var stderr: String
}

final class Buffer: @unchecked Sendable {
  private let lock = NSLock()
  private var text = ""
  func append(_ s: String) {
    lock.lock()
    text += s
    lock.unlock()
  }
  var value: String {
    lock.lock()
    defer { lock.unlock() }
    return text
  }
}

/// Runs the CLI against a fake host, capturing both streams.
func runCLI(
  _ arguments: [String], host: FakeHost = FakeHost(), environment: [String: String] = [:],
  storeRoot: String = "/nonexistent/simslim-tests"
) -> CLIResult {
  let out = Buffer()
  let err = Buffer()
  let cli = CLI(
    version: "test-version", environment: environment, runner: host, storeRoot: storeRoot,
    stdout: { out.append($0) }, stderr: { err.append($0) })
  let status = cli.run(arguments)
  return CLIResult(status: status, stdout: out.value, stderr: err.value)
}

let bootedUDID = "11111111-1111-1111-1111-111111111111"
let shutdownUDID = "22222222-2222-2222-2222-222222222222"
let oldUDID = "33333333-3333-3333-3333-333333333333"

/// A host with a booted iOS 27.2 iPhone, a shut-down iPad, and a booted iOS 18.4
/// iPhone, all partly slimmed.
func standardHost() -> FakeHost {
  let host = FakeHost(devices: [
    .init(udid: shutdownUDID, name: "iPad Air", state: "Shutdown"),
    .init(udid: bootedUDID, name: "iPhone 17", state: "Booted"),
    .init(
      udid: oldUDID, name: "iPhone 16",
      runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-4", state: "Booted"),
  ])
  host.disabled[bootedUDID] = Set(Profile().desired().sorted().prefix(100))
  host.disabled[oldUDID] = []
  host.launchdPIDs = [bootedUDID: 200, oldUDID: 300]
  host.psOutput = """
      PID  PPID  %CPU COMM
      200     1   1.0 /x/launchd_sim
      201   200   2.0 /x/SpringBoard
      300     1   4.0 /x/launchd_sim
    """
  host.topOutput = "PID    MEM\n200    10M\n201    20M\n300    1G\n"
  return host
}
