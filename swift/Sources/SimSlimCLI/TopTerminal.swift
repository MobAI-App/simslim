import Foundation
import SimSlimKit

// The interactive `simslim top`: raw terminal input, an alternate screen, and a
// refresh loop. Everything it decides lives in TopModel; this file only moves
// bytes. Measurements run on their own threads so the screen never waits on one.

private final class TopMailbox: @unchecked Sendable {
  private let lock = NSLock()
  private var messages: [TopMessage] = []

  func post(_ message: TopMessage) {
    lock.lock()
    messages.append(message)
    lock.unlock()
  }

  func drain() -> [TopMessage] {
    lock.lock()
    defer { lock.unlock() }
    let all = messages
    messages = []
    return all
  }
}

/// Turns terminal input bytes into keys. A lone ESC at the end of the input is the
/// Escape key; ESC followed by `[` or `O` and a letter is an arrow key.
func parseTopKeys(_ bytes: [UInt8]) -> [TopKey] {
  var keys: [TopKey] = []
  var i = 0
  while i < bytes.count {
    let b = bytes[i]
    switch b {
    case 0x1B:
      if i + 2 < bytes.count, bytes[i + 1] == 0x5B || bytes[i + 1] == 0x4F {
        switch bytes[i + 2] {
        case 0x41: keys.append(.up)
        case 0x42: keys.append(.down)
        case 0x43: keys.append(.right)
        case 0x44: keys.append(.left)
        default: break
        }
        i += 3
        continue
      }
      keys.append(.escape)
    case 0x03: keys.append(.ctrlC)
    case 0x0D, 0x0A: keys.append(.enter)
    case 0x20...0x7E: keys.append(.character(Character(Unicode.Scalar(b))))
    default: break  // other control bytes and UTF-8 continuation bytes
    }
    i += 1
  }
  return keys
}

private func terminalSize() -> (width: Int, height: Int) {
  var size = winsize()
  if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
    return (Int(size.ws_col), Int(size.ws_row))
  }
  return (0, 0)
}

/// Runs the live monitor until `q`, Ctrl-C, or an interrupt. It restores the
/// terminal on every way out.
func runTopTerminal(
  simctl: Simctl, udid: String, name: String, interrupt: InterruptFlag, write: CLI.Sink
) {
  var original = termios()
  guard tcgetattr(STDIN_FILENO, &original) == 0 else { return }
  var raw = original
  cfmakeraw(&raw)
  raw.c_oflag |= tcflag_t(OPOST)  // keep "\n" meaning a new line
  tcsetattr(STDIN_FILENO, TCSANOW, &raw)
  write("\u{1B}[?1049h\u{1B}[?25l")
  defer {
    write("\u{1B}[?25h\u{1B}[?1049l")
    tcsetattr(STDIN_FILENO, TCSANOW, &original)
  }

  let mailbox = TopMailbox()
  var ctl = simctl
  ctl.cancelled = { interrupt.isSet }
  let work = ctl

  func run(_ effects: [TopEffect]) -> Bool {
    for effect in effects {
      switch effect {
      case .quit:
        return false
      case .refreshFleet:
        Thread.detachNewThread {
          mailbox.post(
            .fleet(
              Result { try work.fleetSnapshot(withDisk: false) }.mapError {
                SimSlimError($0.localizedDescription)
              }))
        }
      case .refreshDisk(let udids):
        Thread.detachNewThread {
          var sizes: [String: Int64] = [:]
          for udid in udids {
            if let bytes = try? work.deviceDiskUsage(udid: udid) { sizes[udid] = bytes }
          }
          mailbox.post(.disk(sizes))
        }
      case .refreshProcs(let udid):
        Thread.detachNewThread {
          mailbox.post(
            .procs(
              udid: udid,
              Result { try work.measureProcesses(udid: udid) }.mapError {
                SimSlimError($0.localizedDescription)
              }))
        }
      }
    }
    return true
  }

  var model = TopModel(drillInto: udid, name: name)
  let size = terminalSize()
  model.width = size.width
  model.height = size.height
  var running = run(model.start())
  var nextTick = Date().addingTimeInterval(topRefresh)
  var lastSize = size
  var dirty = true
  var lastScreen = ""

  while running && !interrupt.isSet {
    let current = terminalSize()
    if current != lastSize {
      lastSize = current
      _ = model.apply(.resize(width: current.width, height: current.height), now: Date())
      dirty = true
    }

    var input = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    if poll(&input, 1, 50) > 0, input.revents & Int16(POLLIN) != 0 {
      var buffer = [UInt8](repeating: 0, count: 64)
      let n = read(STDIN_FILENO, &buffer, buffer.count)
      if n > 0 {
        for key in parseTopKeys(Array(buffer[0..<n])) {
          running = run(model.key(key)) && running
        }
        dirty = true
      } else if n == 0 {
        running = false  // the terminal went away
      }
    }

    for message in mailbox.drain() {
      running = run(model.apply(message, now: Date())) && running
      dirty = true
    }
    if Date() >= nextTick {
      nextTick = Date().addingTimeInterval(topRefresh)
      running = run(model.tick(now: Date())) && running
    }

    if dirty {
      dirty = false
      var lines = model.screenLines()
      if model.height > 0 && lines.count > model.height {
        lines = Array(lines.prefix(model.height))
      }
      let screen = lines.map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J"
      if screen != lastScreen {
        lastScreen = screen
        write("\u{1B}[H" + screen)
      }
    }
  }
}
