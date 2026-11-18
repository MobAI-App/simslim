import Foundation

// launchd_sim is a host process, so a simulator's launchd disable overrides are
// not in the device's data directory: they live beside its launchd.log, keyed
// only by UDID. launchd_sim reads the file when it starts and rewrites it on every
// `launchctl disable`/`enable`. It is an undocumented CoreSimulator detail, so
// everything here is best effort and callers fall back to launchctl.

struct DisabledStore: Sendable {
  var root: String

  func directory(udid: String) -> String {
    (root as NSString).appendingPathComponent("com.apple.CoreSimulator.SimDevice.\(udid)")
  }

  func path(udid: String) -> String {
    (directory(udid: udid) as NSString).appendingPathComponent("disabled.plist")
  }

  /// The labels the store marks disabled; a label absent from the result is
  /// enabled. A device that never booted has no store, which is the same as
  /// nothing disabled.
  func readDisabled(udid: String) throws -> Set<String> {
    Set(try readEntries(udid: udid).filter { $0.value }.keys)
  }

  /// Every entry verbatim, including the explicit-enable (false) entries the
  /// runtime writes for itself, which a merge must preserve.
  func readEntries(udid: String) throws -> [String: Bool] {
    let file = path(udid: udid)
    guard FileManager.default.fileExists(atPath: file) else { return [:] }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: file))
    } catch {
      throw SimSlimError("read launchd disable store: \(error.localizedDescription)")
    }
    return try DisabledStore.parse(data)
  }

  /// Entries whose value is not a boolean, kept verbatim across a write.
  private func readForeign(udid: String) -> [String: Any] {
    let file = path(udid: udid)
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
      let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        as? [String: Any]
    else { return [:] }
    return dict.filter { entry in
      guard let number = entry.value as? NSNumber else { return true }
      return CFGetTypeID(number) != CFBooleanGetTypeID()
    }
  }

  /// Merges the transitions into the store, leaving every other entry as it
  /// was. The write is atomic so launchd_sim never reads a half-written store.
  func write(udid: String, toDisable: [String], toEnable: [String]) throws {
    var entries = try readEntries(udid: udid)
    let foreign = readForeign(udid: udid)
    for label in toDisable { entries[label] = true }
    for label in toEnable { entries[label] = false }

    let dir = directory(udid: udid)
    do {
      try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      throw SimSlimError("create launchd disable store: \(error.localizedDescription)")
    }
    let temp = (dir as NSString).appendingPathComponent("disabled.plist.\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(atPath: temp) }
    do {
      let data: Data
      if foreign.isEmpty {
        data = DisabledStore.encode(entries)
      } else {
        // Entries of another type are not ours to drop; let the plist writer
        // serialize the mixed dictionary.
        var merged: [String: Any] = foreign
        for (label, value) in entries { merged[label] = value }
        data = try PropertyListSerialization.data(
          fromPropertyList: merged, format: .xml, options: 0)
      }
      try data.write(to: URL(fileURLWithPath: temp))
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temp)
    } catch {
      throw SimSlimError("write launchd disable store: \(error.localizedDescription)")
    }
    // rename(2) replaces the destination atomically; FileManager.replaceItem and
    // moveItem would refuse or copy.
    guard rename(temp, path(udid: udid)) == 0 else {
      throw SimSlimError("write launchd disable store: \(String(cString: strerror(errno)))")
    }
  }

  /// The same XML plist shape launchd_sim writes, sorted so a rewrite that
  /// changes nothing produces an identical file.
  static func encode(_ entries: [String: Bool]) -> Data {
    var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
    text +=
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
    text += "<plist version=\"1.0\">\n<dict>\n"
    for label in entries.keys.sorted() {
      text += "\t<key>\(escape(label))</key>\n\t<\(entries[label]! ? "true" : "false")/>\n"
    }
    text += "</dict>\n</plist>\n"
    return Data(text.utf8)
  }

  private static func escape(_ text: String) -> String {
    var out = ""
    for ch in text.unicodeScalars {
      switch ch {
      case "&": out += "&amp;"
      case "<": out += "&lt;"
      case ">": out += "&gt;"
      case "\"": out += "&quot;"
      case "'": out += "&apos;"
      default: out.unicodeScalars.append(ch)
      }
    }
    return out
  }

  /// Reads the flat `<key>label</key><true/>|<false/>` dict. Values of any other
  /// type are ignored rather than rejected, so an unexpected one cannot make the
  /// store unreadable.
  static func parse(_ data: Data) throws -> [String: Bool] {
    // A zero-byte file (a launchd_sim that died mid-write) is an empty store.
    if data.isEmpty { return [:] }
    let object: Any
    var format = PropertyListSerialization.PropertyListFormat.xml
    do {
      object = try PropertyListSerialization.propertyList(
        from: data, options: [], format: &format)
    } catch {
      throw SimSlimError("parse launchd disable store: \(error.localizedDescription)")
    }
    // Foundation also accepts old-style text such as `garbage` as a string plist;
    // only an XML or binary dictionary is a store.
    guard format != .openStep, let dict = object as? [String: Any] else {
      throw SimSlimError(
        "parse launchd disable store: not an XML or binary property list dictionary")
    }
    var entries: [String: Bool] = [:]
    for (label, value) in dict where !label.isEmpty {
      // Only real booleans: an integer 1 is not a disable override.
      if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
        entries[label] = number.boolValue
      }
    }
    return entries
  }
}
