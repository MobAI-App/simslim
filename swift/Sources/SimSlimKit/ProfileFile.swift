// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// The on-disk profile applied with `simslim on --profile <path>`. `except` and
/// `keep` mirror the `--except` and `--keep` flags.
public struct SlimProfile: Equatable, Sendable {
  public var name: String
  public var description: String
  public var except: [String]
  public var keep: [String]

  public init(
    name: String = "", description: String = "", except: [String] = [], keep: [String] = []
  ) {
    self.name = name
    self.description = description
    self.except = except
    self.keep = keep
  }

  /// Turns a parsed SlimProfile into the validated Profile it selects.
  func resolve(path: String) throws -> Profile {
    var profile = Profile()
    for raw in except {
      let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if id.isEmpty { continue }
      guard Catalog.category(id: id) != nil else {
        throw SimSlimError(
          "profile \(path): unknown category \"\(id)\" (see `simslim profiles`)")
      }
      profile.exceptCategories.insert(id)
    }
    // Accept keep entries for required services too: profiles written as
    // workarounds before a service became always-enabled must remain valid.
    for raw in keep {
      let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      if label.isEmpty { continue }
      guard Catalog.managedSet.contains(label) else {
        throw SimSlimError(
          "profile \(path): \"\(label)\" is not a managed daemon (see `simslim profiles`)")
      }
      profile.keep.insert(label)
    }
    return profile
  }
}

/// Reads a profile file and resolves it to a validated Profile.
///
/// Like the Go version it rejects unknown fields and matches field names
/// case-insensitively. Unlike it, a malformed document with trailing text after
/// the first JSON value is rejected rather than ignored. Foundation's parser also
/// accepts what Go's rejects (trailing commas, a UTF-8 byte-order mark) and keeps
/// the first of two identical keys where Go keeps the last; a file that relies on
/// any of these reads differently here.
public func loadSlimProfile(path: String) throws -> Profile {
  let data: Data
  do {
    data = try Data(contentsOf: URL(fileURLWithPath: path))
  } catch {
    throw SimSlimError("read profile \(path): \(readFailureReason(error))")
  }
  return try parseSlimProfile(data, path: path).resolve(path: path)
}

func parseSlimProfile(_ data: Data, path: String) throws -> SlimProfile {
  let trimmed = String(decoding: data, as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty {
    throw SimSlimError("profile \(path) is empty; write {} for the default profile")
  }

  let parsed: Any
  do {
    parsed = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  } catch {
    throw SimSlimError("parse profile \(path): \(error.localizedDescription)")
  }

  // JSON null decodes to the zero value, as in Go.
  if parsed is NSNull { return SlimProfile() }
  guard let object = parsed as? [String: Any] else {
    throw SimSlimError("parse profile \(path): the top level must be a JSON object")
  }

  var profile = SlimProfile()
  for (key, value) in object {
    switch key.lowercased() {
    case "name": profile.name = try stringValue(value, field: "name", path: path)
    case "description":
      profile.description = try stringValue(value, field: "description", path: path)
    case "except": profile.except = try stringList(value, field: "except", path: path)
    case "keep": profile.keep = try stringList(value, field: "keep", path: path)
    default: throw SimSlimError("parse profile \(path): unknown field \"\(key)\"")
    }
  }
  return profile
}

private func stringValue(_ value: Any, field: String, path: String) throws -> String {
  if value is NSNull { return "" }
  guard let string = value as? String else {
    throw SimSlimError("parse profile \(path): field \"\(field)\" must be a string")
  }
  return string
}

private func stringList(_ value: Any, field: String, path: String) throws -> [String] {
  if value is NSNull { return [] }
  guard let array = value as? [Any] else {
    throw SimSlimError("parse profile \(path): field \"\(field)\" must be an array of strings")
  }
  return try array.map { element in
    if element is NSNull { return "" }
    guard let string = element as? String else {
      throw SimSlimError("parse profile \(path): field \"\(field)\" must be an array of strings")
    }
    return string
  }
}

private func readFailureReason(_ error: Error) -> String {
  let ns = error as NSError
  if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
    return String(cString: strerror(Int32(posix.code))).lowercased()
  }
  return ns.localizedDescription
}

/// Parses the comma-separated list syntax shared by the `--except`, `--keep`,
/// `--requires` and `--categories` flags, dropping blank entries.
public func splitList(_ text: String) -> [String] {
  text.split(separator: ",", omittingEmptySubsequences: false)
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
}

/// Selects the slim profile for an `on` invocation. A `--profile` file is the
/// single source of truth, so it cannot be combined with `--except`/`--keep`.
public func buildProfile(profilePath: String, except: String, keep: String) throws -> Profile {
  if !profilePath.isEmpty {
    if !except.isEmpty || !keep.isEmpty {
      throw SimSlimError("--profile cannot be combined with --except or --keep")
    }
    return try loadSlimProfile(path: profilePath)
  }
  var profile = Profile()
  for id in splitList(except) {
    guard Catalog.category(id: id) != nil else {
      throw SimSlimError("unknown category \"\(id)\" (see `simslim profiles`)")
    }
    profile.exceptCategories.insert(id)
  }
  for label in splitList(keep) {
    profile.keep.insert(label)
  }
  return profile
}

/// Renders a profile as indented JSON with a trailing newline, in the same
/// field order and escaping as the Go encoder (so files round-trip between the
/// two tools without churn): name, description, except, keep; empty fields are
/// omitted; `<`, `>`, `&`, U+2028 and U+2029 are escaped.
public func marshalProfile(_ profile: SlimProfile) -> Data {
  var fields: [String] = []
  if !profile.name.isEmpty { fields.append("  \"name\": \(goJSONString(profile.name))") }
  if !profile.description.isEmpty {
    fields.append("  \"description\": \(goJSONString(profile.description))")
  }
  if !profile.except.isEmpty { fields.append(jsonList("except", profile.except)) }
  if !profile.keep.isEmpty { fields.append(jsonList("keep", profile.keep)) }

  let body = fields.isEmpty ? "{}" : "{\n" + fields.joined(separator: ",\n") + "\n}"
  return Data((body + "\n").utf8)
}

private func jsonList(_ key: String, _ items: [String]) -> String {
  let rendered = items.map { "    \(goJSONString($0))" }.joined(separator: ",\n")
  return "  \"\(key)\": [\n\(rendered)\n  ]"
}

private func goJSONString(_ value: String) -> String {
  var out = "\""
  for scalar in value.unicodeScalars {
    switch scalar {
    case "\"": out += "\\\""
    case "\\": out += "\\\\"
    case "\n": out += "\\n"
    case "\r": out += "\\r"
    case "\t": out += "\\t"
    case "\u{08}": out += "\\b"
    case "\u{0C}": out += "\\f"
    case "<": out += "\\u003c"
    case ">": out += "\\u003e"
    case "&": out += "\\u0026"
    case "\u{2028}": out += "\\u2028"
    case "\u{2029}": out += "\\u2029"
    default:
      if scalar.value < 0x20 {
        out += String(format: "\\u%04x", scalar.value)
      } else {
        out.unicodeScalars.append(scalar)
      }
    }
  }
  return out + "\""
}

/// Derives a JSON filename from a profile name, for when the command targets a
/// directory. Runs of characters that are not filename-safe collapse to a
/// hyphen; an empty name falls back to `profile.json`.
public func profileFileName(_ name: String) -> String {
  var slug = ""
  var previousDash = false
  for scalar in name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
    switch scalar {
    case "a"..."z", "0"..."9", "_", ".":
      slug.unicodeScalars.append(scalar)
      previousDash = false
    default:
      if !previousDash {
        slug += "-"
        previousDash = true
      }
    }
  }
  slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
  if slug.isEmpty { return "profile.json" }
  if slug.hasSuffix(".json") { return slug }
  return slug + ".json"
}
