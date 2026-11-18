// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

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
  /// The exit status, or the negated signal number if the process was killed.
  public var status: Int32
  public var stdout: Data
  public var stderr: Data
  /// True when the runner killed the process for exceeding its timeout.
  public var timedOut: Bool

  public init(
    status: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false
  ) {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
    self.timedOut = timedOut
  }

  public var succeeded: Bool { status == 0 && !timedOut }
  public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
  public var stderrText: String { String(decoding: stderr, as: UTF8.self) }

  /// stdout followed by stderr, trimmed: what Go's CombinedOutput would show.
  public var combinedText: String {
    (stdoutText + stderrText).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// The seam tests use to replace real processes with a fake.
public protocol CommandRunning: Sendable {
  /// Runs `executable` and returns its result. A non-zero exit is a result, not
  /// an error; only a failure to start the process throws. With a `timeout`
  /// the process is killed when it expires and `timedOut` is set.
  func run(_ executable: Executable, _ arguments: [String], timeout: TimeInterval?) throws
    -> CommandResult
}

extension CommandRunning {
  public func run(_ executable: Executable, _ arguments: [String]) throws -> CommandResult {
    try run(executable, arguments, timeout: nil)
  }
}

public struct SystemCommandRunner: CommandRunning {
  /// How long to keep reading a finished process's output pipes. When a timed-out
  /// `xcrun` is killed, the `simctl` child it started can still hold the pipe;
  /// without this bound the read would never return.
  var waitDelay: TimeInterval
  /// Maps an Executable to the path to start. Always the real path outside tests.
  var resolve: @Sendable (Executable) -> String

  public init() {
    self.init(waitDelay: 5, resolve: { $0.rawValue })
  }

  init(waitDelay: TimeInterval, resolve: @escaping @Sendable (Executable) -> String) {
    self.waitDelay = waitDelay
    self.resolve = resolve
  }

  public func run(_ executable: Executable, _ arguments: [String], timeout: TimeInterval?) throws
    -> CommandResult
  {
    let path = resolve(executable)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    let outCollector = Collector(out)
    let errCollector = Collector(err)
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }

    do {
      try process.run()
    } catch {
      outCollector.abandon()
      errCollector.abandon()
      throw SimSlimError("cannot run \(path): \(error.localizedDescription)")
    }
    // The child holds its own copies; ours must close or EOF never arrives.
    try? out.fileHandleForWriting.close()
    try? err.fileHandleForWriting.close()

    let timeoutState = TimeoutState()
    var killer: DispatchWorkItem?
    if let timeout {
      let pid = process.processIdentifier
      let item = DispatchWorkItem {
        if timeoutState.markTimedOut(ifRunning: process) { kill(pid, SIGKILL) }
      }
      killer = item
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    exited.wait()
    killer?.cancel()

    // After exit the pipes normally reach EOF at once. If a grandchild still
    // holds one open, give it `waitDelay` and then stop waiting.
    let deadline = DispatchTime.now() + waitDelay
    let outDone = outCollector.waitForEOF(until: deadline)
    let errDone = errCollector.waitForEOF(until: deadline)
    if !outDone { outCollector.abandon() }
    if !errDone { errCollector.abandon() }

    var status = process.terminationStatus
    if process.terminationReason == .uncaughtSignal { status = -status }
    return CommandResult(
      status: status, stdout: outCollector.data, stderr: errCollector.data,
      timedOut: timeoutState.timedOut)
  }
}

/// Reads a pipe through its readability handler so a pipe that never closes can
/// be abandoned instead of blocking a thread forever.
private final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let eof = DispatchSemaphore(value: 0)
  private let handle: FileHandle

  init(_ pipe: Pipe) {
    handle = pipe.fileHandleForReading
    handle.readabilityHandler = { [weak self] h in
      guard let self else { return }
      let chunk = h.availableData
      if chunk.isEmpty {
        h.readabilityHandler = nil
        self.eof.signal()
      } else {
        self.lock.lock()
        self.buffer.append(chunk)
        self.lock.unlock()
      }
    }
  }

  var data: Data {
    lock.lock()
    defer { lock.unlock() }
    return buffer
  }

  func waitForEOF(until deadline: DispatchTime) -> Bool {
    eof.wait(timeout: deadline) == .success
  }

  func abandon() {
    handle.readabilityHandler = nil
  }
}

private final class TimeoutState: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false

  var timedOut: Bool {
    lock.lock()
    defer { lock.unlock() }
    return flag
  }

  /// Records the timeout only if the process is still running, so a process
  /// that exits just before the timer fires is not reported as timed out.
  func markTimedOut(ifRunning process: Process) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard process.isRunning else { return false }
    flag = true
    return true
  }
}
