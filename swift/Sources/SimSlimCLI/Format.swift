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
