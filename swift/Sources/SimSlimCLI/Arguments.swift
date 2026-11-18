import Foundation
import SimSlimKit

struct FlagSpec {
  let name: String
  let isBool: Bool
  var onlyOnce = false

  static func bool(_ name: String, onlyOnce: Bool = false) -> FlagSpec {
    FlagSpec(name: name, isBool: true, onlyOnce: onlyOnce)
  }
  static func string(_ name: String) -> FlagSpec { FlagSpec(name: name, isBool: false) }
}

struct ParsedArguments {
  var positionals: [String] = []
  var bools: [String: Bool] = [:]
  var strings: [String: String] = [:]

  func bool(_ name: String) -> Bool { bools[name] ?? false }
  func string(_ name: String) -> String { strings[name] ?? "" }
  func has(_ name: String) -> Bool { bools[name] != nil || strings[name] != nil }
}

/// Parses flags and positionals in any order (`on <udid> --except search` and
/// `on --except search <udid>` are the same), as the Go CLI does. Accepts `-flag`
/// and `--flag`, `--flag=value` and `--flag value`; `--` ends flag parsing. A bool
/// flag never consumes the next token.
func parseArguments(_ tokens: [String], specs: [FlagSpec]) throws -> ParsedArguments {
  var parsed = ParsedArguments()
  var i = 0
  while i < tokens.count {
    let token = tokens[i]
    i += 1
    if token == "--" {
      parsed.positionals.append(contentsOf: tokens[i...])
      break
    }
    guard token.hasPrefix("-"), token.count > 1 else {
      parsed.positionals.append(token)
      continue
    }

    let body = token.drop(while: { $0 == "-" })
    let name: String
    var inline: String?
    if let eq = body.firstIndex(of: "=") {
      name = String(body[..<eq])
      inline = String(body[body.index(after: eq)...])
    } else {
      name = String(body)
    }
    guard let spec = specs.first(where: { $0.name == name }) else {
      throw SimSlimError("flag provided but not defined: -\(name)")
    }
    if spec.onlyOnce && parsed.has(name) {
      throw SimSlimError("flag --\(name) can only be used once")
    }

    if spec.isBool {
      switch inline?.lowercased() {
      case nil, "true", "1", "t": parsed.bools[name] = true
      case "false", "0", "f": parsed.bools[name] = false
      default:
        throw SimSlimError("invalid value \"\(inline ?? "")\" for flag -\(name): parse error")
      }
    } else if let inline {
      parsed.strings[name] = inline
    } else if i < tokens.count {
      parsed.strings[name] = tokens[i]
      i += 1
    } else {
      throw SimSlimError("flag needs an argument: --\(name)")
    }
  }
  return parsed
}
