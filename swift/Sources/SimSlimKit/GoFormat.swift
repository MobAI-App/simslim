import Foundation

/// Go's `%q` (`strconv.Quote`): quote, backslash and the C escapes are
/// escaped, and so is every scalar Go does not call printable (anything outside
/// the letter, mark, number, punctuation and symbol categories and the ASCII
/// space), as `\uXXXX` or `\UXXXXXXXX`. A name such as one with a zero-width
/// joiner therefore prints visibly escaped, as it does in Go.
public func goQuote(_ text: String) -> String {
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
        out += "\\u" + hexDigits(ch.value, width: 4)
      } else {
        out += "\\U" + hexDigits(ch.value, width: 8)
      }
    }
  }
  return out + "\""
}

func hexDigits(_ value: UInt32, width: Int) -> String {
  let digits = String(value, radix: 16)
  return String(repeating: "0", count: max(0, width - digits.count)) + digits
}

func isGoPrintable(_ scalar: Unicode.Scalar) -> Bool {
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
