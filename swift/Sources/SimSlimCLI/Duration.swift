import Foundation
import SimSlimKit

/// Parses durations the way Go's time.ParseDuration does ("90s", "10m", "1h30m",
/// "1.5h", "500ms"), so `--boot-timeout 15m` and SIMSLIM_BOOT_TIMEOUT behave the
/// same in both tools. Returns seconds.
func parseGoDuration(_ text: String) throws -> TimeInterval {
  let invalid = SimSlimErrorMessage.invalidDuration(text)
  var rest = Substring(text)
  var sign = 1.0
  if let first = rest.first, first == "-" || first == "+" {
    if first == "-" { sign = -1 }
    rest = rest.dropFirst()
  }
  if rest == "0" { return 0 }
  if rest.isEmpty { throw invalid }

  let units: [(String, Double)] = [
    ("ns", 1e-9), ("us", 1e-6), ("µs", 1e-6), ("μs", 1e-6), ("ms", 1e-3),
    ("s", 1), ("m", 60), ("h", 3600),
  ]
  var total = 0.0
  while !rest.isEmpty {
    var number = ""
    while let c = rest.first, c.isASCII, c.isNumber || c == "." {
      number.append(c)
      rest = rest.dropFirst()
    }
    guard !number.isEmpty, let value = Double(number) else { throw invalid }
    var unit = ""
    while let c = rest.first, !(c.isASCII && (c.isNumber || c == ".")) {
      unit.append(c)
      rest = rest.dropFirst()
    }
    if unit.isEmpty { throw SimSlimErrorMessage.missingUnit(text) }
    guard let scale = units.first(where: { $0.0 == unit })?.1 else {
      throw SimSlimErrorMessage.unknownUnit(unit, text)
    }
    total += value * scale
  }
  return sign * total
}

enum SimSlimErrorMessage {
  static func invalidDuration(_ s: String) -> SimSlimError {
    SimSlimError("time: invalid duration \"\(s)\"")
  }
  static func missingUnit(_ s: String) -> SimSlimError {
    SimSlimError("time: missing unit in duration \"\(s)\"")
  }
  static func unknownUnit(_ unit: String, _ s: String) -> SimSlimError {
    SimSlimError("time: unknown unit \"\(unit)\" in duration \"\(s)\"")
  }
}
