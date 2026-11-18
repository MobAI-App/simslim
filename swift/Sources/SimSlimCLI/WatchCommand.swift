import Foundation
import SimSlimKit

/// Set when the user presses Ctrl-C (or a test calls `trigger`). `install` makes
/// SIGINT and SIGTERM set it instead of killing the process, so `watch` can stop
/// its in-flight work and return; only `watch` installs it.
public final class InterruptFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var set = false
  private var sources: [DispatchSourceSignal] = []

  public init() {}

  public var isSet: Bool {
    lock.lock()
    defer { lock.unlock() }
    return set
  }

  public func trigger() {
    lock.lock()
    set = true
    lock.unlock()
  }

  func install() {
    lock.lock()
    defer { lock.unlock() }
    if !sources.isEmpty { return }
    for sig in [SIGINT, SIGTERM] {
      signal(sig, SIG_IGN)
      // The main thread is busy running the command, so handle on a global queue.
      let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
      source.setEventHandler { [weak self] in self?.trigger() }
      source.resume()
      sources.append(source)
    }
  }
}

extension CLI {
  func cmdWatch(_ context: Context) throws -> Int32 {
    let parsed = context.parsed
    guard parsed.positionals.isEmpty else { throw SimSlimError("watch takes no arguments") }
    let profile = try buildProfile(
      profilePath: parsed.string("profile"), except: parsed.string("except"),
      keep: parsed.string("keep"))
    var interval = defaultWatchInterval
    if parsed.has("interval") {
      let raw = parsed.string("interval")
      do {
        interval = try parseGoDuration(raw)
      } catch {
        throw SimSlimError(
          "invalid value \"\(raw)\" for flag -interval: \((error as? SimSlimError)?.message ?? "parse error")"
        )
      }
    }

    let simctl = context.simctl
    let interrupt = context.interrupt
    interrupt.install()
    let stop: @Sendable () -> Bool = { interrupt.isSet }
    let stdout = context.stdout
    let stderr = context.stderr

    let watcher: Watcher
    if parsed.bool("json") {
      // One JSON object per event, from several threads at once.
      let lock = NSLock()
      watcher = Watcher(
        simctl: simctl, profile: profile, home: context.home, report: nil,
        events: { event in
          lock.lock()
          stdout(event.jsonLine + "\n")
          lock.unlock()
        })
    } else {
      let sets = simctl.knownSets.map(\.name)
      stderr(
        "Watching device sets [\(sets.joined(separator: ", "))]; slimming each simulator before it boots where its runtime allows, and no-reboot as it boots. Ctrl-C to stop.\n"
      )
      watcher = Watcher(
        simctl: simctl, profile: profile, home: context.home, report: { stderr($0 + "\n") })
    }
    watcher.run(interval: interval, stop: stop)
    return 0
  }
}
