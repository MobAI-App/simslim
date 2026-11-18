import Foundation
import SimSlimKit

extension CLI {
  func cmdTop(_ context: Context) throws -> Int32 {
    let args = context.parsed.positionals
    guard args.count <= 1 else { throw SimSlimError("top takes at most one simulator UDID") }
    let udid = args.first ?? ""
    let simctl = context.simctl

    /// A friendly name for a UDID, empty when it cannot be resolved so the output
    /// degrades to the short UDID.
    func deviceName() -> String {
      udid.isEmpty ? "" : ((try? simctl.findDevice(udid: udid))?.name ?? "")
    }
    func processes() throws -> TopProcesses {
      let list = try simctl.measureProcesses(udid: udid)
      return TopProcesses(
        udid: udid, name: deviceName(), processes: list,
        totalBytes: list.reduce(0) { $0 + $1.bytes })
    }

    // --json and piped output are one-shot; the live screen needs a real terminal.
    if context.parsed.bool("json") {
      context.stdout(
        udid.isEmpty
          ? try jsonText(try simctl.fleetSnapshot(withDisk: true)) : try jsonText(try processes()))
      return 0
    }
    if !context.isInteractive {
      context.stdout(
        udid.isEmpty
          ? staticFleet(try simctl.fleetSnapshot(withDisk: false)) : staticProcs(try processes()))
      return 0
    }

    context.interrupt.install()
    runTopTerminal(
      simctl: simctl, udid: udid, name: deviceName(), interrupt: context.interrupt,
      write: context.stdout)
    return 0
  }
}
