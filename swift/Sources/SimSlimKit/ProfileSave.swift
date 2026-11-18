import Foundation

// `enable --save` / `disable --save`: record the change in a profile file, the one
// place that describes a slim simulator, so `on`, `watch` and `verify` with that
// profile agree with it.

extension Catalog {
  /// Every managed label the categories and labels name.
  static func covered(categories ids: [String], labels: [String]) -> Set<String> {
    var covered = Set<String>()
    for id in ids {
      if let category = category(id: id) { covered.formUnion(category.labels) }
    }
    for label in labels where managedSet.contains(label) { covered.insert(label) }
    return covered
  }
}

/// Reads and validates a profile file, keeping its entries as written. A missing
/// file is the default profile.
func readSlimProfile(path: String) throws -> (profile: SlimProfile, exists: Bool) {
  guard FileManager.default.fileExists(atPath: path) else { return (SlimProfile(), false) }
  let data: Data
  do {
    data = try Data(contentsOf: URL(fileURLWithPath: path))
  } catch {
    throw SimSlimError("read profile \(path): \(error.localizedDescription)")
  }
  let profile = try parseSlimProfile(data, path: path)
  _ = try profile.resolve(path: path)
  return (profile, true)
}

/// The profile at `path` with the change applied, and whether anything changed.
/// Writes nothing. Enabling adds each category to `except` and each daemon to
/// `keep`, unless an excepted category already keeps it; disabling removes them.
func updatedProfile(path: String, categories: [String], labels: [String], enable: Bool) throws
  -> (data: Data?, changed: Bool)
{
  var (profile, exists) = try readSlimProfile(path: path)
  let beforeExcept = profile.except
  let beforeKeep = profile.keep
  if enable {
    for id in categories where !profile.except.contains(id) { profile.except.append(id) }
    let excepted = Catalog.covered(categories: profile.except, labels: [])
    for label in labels where !excepted.contains(label) && !profile.keep.contains(label) {
      profile.keep.append(label)
    }
  } else {
    profile.except.removeAll { categories.contains($0) }
    profile.keep.removeAll { labels.contains($0) }
    // Removing a daemon from `keep` is not enough while a category the profile
    // still excepts lists it.
    for label in labels {
      for id in profile.except where Catalog.covered(categories: [id], labels: []).contains(label) {
        throw SimSlimError(
          "profile \(path) keeps \(label) enabled through category \"\(id)\"; disable that category instead, or edit the file"
        )
      }
    }
  }
  if exists && beforeExcept == profile.except && beforeKeep == profile.keep { return (nil, false) }
  return (marshalProfile(profile), true)
}

/// Records an `enable` or `disable` in a profile file. An unchanged profile is
/// not rewritten; a changed one is replaced atomically.
public func saveServices(path: String, categories: [String], labels: [String], enable: Bool) throws
{
  let (data, changed) = try updatedProfile(
    path: path, categories: categories, labels: labels, enable: enable)
  guard changed, let data else { return }
  try writeFileAtomic(path: path, data: data)
}

/// Replaces `path` through a temporary file in the same directory, so a
/// concurrent reader sees the old file or the new one, never half of it. A
/// symlink is followed, and an existing file keeps its mode.
func writeFileAtomic(path original: String, data: Data) throws {
  var path = original
  var mode = 0o644
  let resolved = (original as NSString).resolvingSymlinksInPath
  if FileManager.default.fileExists(atPath: resolved) {
    path = resolved
    if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let perm = attrs[.posixPermissions] as? Int
    {
      mode = perm & 0o777
    }
  }
  let dir = (path as NSString).deletingLastPathComponent
  let base = (path as NSString).lastPathComponent
  let temp = ((dir.isEmpty ? "." : dir) as NSString).appendingPathComponent(
    ".\(base).\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(atPath: temp) }
  do {
    guard FileManager.default.createFile(atPath: temp, contents: nil) else {
      throw SimSlimError("cannot create \(temp)")
    }
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: temp))
    try handle.write(contentsOf: data)
    try handle.synchronize()
    try handle.close()
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: temp)
  } catch {
    throw SimSlimError("write profile \(path): \(error.localizedDescription)")
  }
  guard rename(temp, path) == 0 else {
    throw SimSlimError("write profile \(path): \(String(cString: strerror(errno)))")
  }
}
