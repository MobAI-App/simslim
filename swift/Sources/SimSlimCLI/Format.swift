import Foundation
import SimSlimKit

/// Pads on the right to `width`, counting Unicode scalars like Go's `%-Ns`.
func padRight(_ text: String, _ width: Int) -> String {
  let count = text.unicodeScalars.count
  return count >= width ? text : text + String(repeating: " ", count: width - count)
}

/// Shortens to at most `limit` scalars, ending with an ellipsis when cut.
func truncate(_ text: String, _ limit: Int) -> String {
  let scalars = Array(text.unicodeScalars)
  if scalars.count <= limit { return text }
  if limit <= 1 { return "…" }
  var out = String.UnicodeScalarView()
  out.append(contentsOf: scalars[..<(limit - 1)])
  return String(out) + "…"
}

func humanBytes(_ bytes: Int64) -> String {
  switch bytes {
  case (1 << 30)...: return String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
  case (1 << 20)...: return String(format: "%.0f MB", Double(bytes) / Double(1 << 20))
  case (1 << 10)...: return String(format: "%.0f KB", Double(bytes) / Double(1 << 10))
  default: return "\(bytes) B"
  }
}

/// Renders machine-readable output: indented, keys sorted so the output is
/// deterministic, with a trailing newline. (Go emits struct-field order; JSON
/// consumers do not depend on key order.)
func jsonText<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self) + "\n"
}

/// Go's `%q` (`strconv.Quote`): quote, backslash and the C escapes are
/// escaped, and so is every scalar Go does not call printable (anything outside
/// the letter, mark, number, punctuation and symbol categories and the ASCII
/// space), as `\uXXXX` or `\UXXXXXXXX`. A name such as one with a zero-width
/// joiner therefore prints visibly escaped, as it does in Go.
func goQuote(_ text: String) -> String {
  var out = "\""
  for ch in text.unicodeScalars {
    switch ch {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\u{07}": out += "\\a"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{0B}": out += "\\v"
    default:
      if isGoPrintable(ch) {
        out.unicodeScalars.append(ch)
      } else if ch.value < 0x10000 {
        out += "\\u" + hex(ch.value, width: 4)
      } else {
        out += "\\U" + hex(ch.value, width: 8)
      }
    }
  }
  return out + "\""
}

private func hex(_ value: UInt32, width: Int) -> String {
  let digits = String(value, radix: 16)
  return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

private func isGoPrintable(_ scalar: Unicode.Scalar) -> Bool {
  if scalar == " " { return true }
  switch scalar.properties.generalCategory {
  case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
    .nonspacingMark, .spacingMark, .enclosingMark,
    .decimalNumber, .letterNumber, .otherNumber,
    .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
    .initialPunctuation, .finalPunctuation, .otherPunctuation,
    .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
    return true
  default:
    return false
  }
}
