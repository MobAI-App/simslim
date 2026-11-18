import Foundation
import SimSlimKit

/// Where `simslim profile` gets its input. The default talks to the terminal;
/// tests supply a script.
struct WizardInput {
  /// Reads one line in normal (cooked) mode; nil at end of input.
  var readLine: (_ prompt: String) -> String?
  /// Puts the terminal in per-key mode; returns its height and a restore function.
  var enterRaw: () -> (rows: Int, restore: () -> Void)?
  /// The next keystroke; nil at end of input.
  var nextKey: () -> TopKey?

  static func terminal(write: @escaping CLI.Sink) -> WizardInput {
    var pending: [TopKey] = []
    return WizardInput(
      readLine: { prompt in
        write(prompt)
        // One byte at a time: a buffered reader would swallow the keys that follow.
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while read(STDIN_FILENO, &byte, 1) == 1 {
          if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
          bytes.append(byte)
        }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
      },
      enterRaw: {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return nil }
        var raw = original
        cfmakeraw(&raw)
        raw.c_oflag |= tcflag_t(OPOST)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return nil }
        write("\u{1B}[?1049h\u{1B}[?25l")
        var size = winsize()
        var rows = 24
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_row >= 6 {
          rows = Int(size.ws_row)
        }
        return (
          rows,
          {
            write("\u{1B}[?25h\u{1B}[?1049l")
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
          }
        )
      },
      nextKey: {
        while pending.isEmpty {
          var buffer = [UInt8](repeating: 0, count: 64)
          let n = read(STDIN_FILENO, &buffer, buffer.count)
          if n <= 0 { return nil }
          pending = parseTopKeys(Array(buffer[0..<n]))
        }
        return pending.removeFirst()
      })
  }
}

extension CLI {
  func cmdProfile(_ context: Context) throws -> Int32 {
    let args = context.parsed.positionals
    guard args.count <= 1 else { throw SimSlimError("profile takes an optional output path") }
    let dest = args.first ?? ""

    var intoDir = false
    if !dest.isEmpty {
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: dest, isDirectory: &isDir) {
        if isDir.boolValue {
          intoDir = true
        } else {
          throw SimSlimError("refusing to overwrite \(dest)")
        }
      }
    }
    guard context.isInteractive else {
      throw SimSlimError("profile is interactive; run it in a terminal")
    }

    let input = context.wizardInput
    context.stderr("Create a slim profile.\n\n")
    let name = (input.readLine("Name (optional): ") ?? "").trimmingCharacters(
      in: .whitespacesAndNewlines)
    let description = (input.readLine("Description (optional): ") ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let raw = input.enterRaw() else { throw SimSlimError("enter raw mode: not a terminal") }
    var model = WizardModel(termRows: raw.rows)
    context.stderr(model.frame())
    while model.outcome == .running {
      guard let key = input.nextKey() else {
        model.key(.ctrlC)  // end of input cancels, like Go
        break
      }
      model.key(key)
      if model.outcome == .running { context.stderr(model.frame()) }
    }
    raw.restore()
    guard model.outcome == .saved else {
      context.stderr("Cancelled; no profile written.\n")
      return 0
    }

    let chosen = model.selection()
    let data = marshalProfile(
      SlimProfile(name: name, description: description, except: chosen.except, keep: chosen.keep))
    context.stderr(
      "Keeping \(chosen.except.count) feature(s) fully enabled and \(chosen.keep.count) individual daemon(s); slimming the rest.\n"
    )
    let text = String(decoding: data, as: UTF8.self)

    if dest.isEmpty {
      context.stdout(text)
      return 0
    }
    let path = intoDir ? (dest as NSString).appendingPathComponent(profileFileName(name)) : dest
    // Exclusive create: never replace a file, even one that appeared during the wizard.
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
    if fd < 0 {
      if errno == EEXIST && intoDir {
        context.stdout(text)
        throw SimSlimError(
          "\(path) already exists; printed the profile above instead of overwriting it")
      }
      if errno == EEXIST { throw SimSlimError("refusing to overwrite \(dest)") }
      throw SimSlimError("write \(path): \(String(cString: strerror(errno)))")
    }
    defer { close(fd) }
    let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard written == data.count else {
      unlink(path)
      throw SimSlimError("write \(path): \(String(cString: strerror(errno)))")
    }
    context.stderr("Wrote \(path). Apply it with `simslim on <udid> --profile \(path)`.\n")
    return 0
  }
}
