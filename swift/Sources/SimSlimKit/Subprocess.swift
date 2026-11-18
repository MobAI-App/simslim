import Foundation

/// Every program simslim may start. This is a closed list of absolute paths:
/// nothing is looked up through PATH, and `Process` is used only in this file
/// (`scripts/verify-deps.sh` enforces both).
public enum Executable: String, CaseIterable, Sendable {
  case xcrun = "/usr/bin/xcrun"
  case plutil = "/usr/bin/plutil"
  case du = "/usr/bin/du"
  case pgrep = "/usr/bin/pgrep"
  case ps = "/bin/ps"
  case top = "/usr/bin/top"
  case lsof = "/usr/sbin/lsof"
}

public struct CommandResult: Equatable, Sendable {
  public var status: Int32
  public var stdout: Data
  public var stderr: Data

  public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }

  public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
  public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// The seam tests use to replace real processes with a fake.
public protocol CommandRunning: Sendable {
  func run(_ executable: Executable, _ arguments: [String]) throws -> CommandResult
}

public struct SystemCommandRunner: CommandRunning {
  public init() {}

  public func run(_ executable: Executable, _ arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable.rawValue)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    try process.run()

    // Drain both pipes while the child runs; waiting first can deadlock when
    // the child fills a pipe buffer.
    var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      errData = err.fileHandleForReading.readDataToEndOfFile()
      errDone.signal()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    process.waitUntilExit()

    return CommandResult(status: process.terminationStatus, stdout: outData, stderr: errData)
  }
}
