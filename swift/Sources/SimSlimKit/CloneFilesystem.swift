import Foundation

// The file-system half of `clone` and `repair-clone`: everything that turns the
// raw copy CoreSimulator makes into a device that no longer points into its
// source. All of it runs while both devices are shut down. Paths are judged
// byte by byte, symlinks are never followed, and every deletion goes through the
// same containment checks the disk cleanup uses.

/// The four directories and two log directories a clone is built from.
struct CloneFilesystem {
  var sourceUDID: String
  var cloneUDID: String
  var sourceDeviceDirectory: String
  var cloneDeviceDirectory: String
  var sourceDataDirectory: String
  var cloneDataDirectory: String
  var sourceLogDirectory: String
  var cloneLogDirectory: String
}

// MARK: - Path logic

private let slashByte = UInt8(ascii: "/")

private func components(_ path: String) -> [[UInt8]] {
  Array(cleanPath(path).utf8).split(separator: slashByte, omittingEmptySubsequences: true).map {
    Array($0)
  }
}

/// Maps a path below `sourceRoot` to the same place below `cloneRoot`; nil when
/// the path is not at or below the source root (or either is not absolute).
func rebasePath(_ path: String, sourceRoot: String, cloneRoot: String) -> String? {
  let root = cleanPath(sourceRoot)
  let target = cleanPath(path)
  guard root.utf8.first == slashByte, target.utf8.first == slashByte else { return nil }
  if Array(root.utf8) == Array(target.utf8) { return cleanPath(cloneRoot) }
  guard isStrictDescendant(root, target) else { return nil }
  let skip = root == "/" ? 1 : root.utf8.count + 1
  let relative = String(decoding: Array(target.utf8).dropFirst(skip), as: UTF8.self)
  return cleanPath(join(cloneRoot, relative))
}

/// `target` expressed relative to the directory `base` (both absolute).
func relativePath(from base: String, to target: String) -> String {
  let from = components(base)
  let to = components(target)
  var common = 0
  while common < from.count && common < to.count && from[common] == to[common] { common += 1 }
  var parts = Array(repeating: "..", count: from.count - common)
  parts += to[common...].map { String(decoding: $0, as: UTF8.self) }
  return parts.isEmpty ? "." : parts.joined(separator: "/")
}

/// Whether any component of the cleaned path is exactly `component`.
func pathContainsComponent(_ path: String, _ component: String) -> Bool {
  if component.isEmpty { return false }
  let wanted = Array(component.utf8)
  return cleanPath(path).utf8.split(separator: slashByte, omittingEmptySubsequences: false)
    .contains { Array($0) == wanted }
}

private func directoryName(_ path: String) -> String {
  let bytes = Array(cleanPath(path).utf8)
  guard let last = bytes.lastIndex(of: slashByte) else { return "." }
  return last == 0 ? "/" : String(decoding: bytes[..<last], as: UTF8.self)
}

private func errnoText() -> String { String(cString: strerror(errno)) }

private func readLink(_ path: String) throws -> String {
  var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
  let n = readlink(path, &buffer, buffer.count - 1)
  guard n >= 0 else { throw SimSlimError("readlink \(path): \(errnoText())") }
  return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The cleaned absolute target of a symlink: a relative one is read from the
/// link's own directory.
private func resolvedLinkTarget(_ link: String, _ target: String) -> String {
  target.utf8.first == slashByte ? cleanPath(target) : cleanPath(join(directoryName(link), target))
}

private func kind(_ info: stat) -> mode_t { info.st_mode & S_IFMT }

// MARK: - Validation

func validateCloneFilesystem(_ paths: CloneFilesystem) throws {
  if paths.sourceUDID.isEmpty || paths.cloneUDID.isEmpty || paths.sourceUDID == paths.cloneUDID {
    throw SimSlimError("clone source and destination UDIDs must be distinct")
  }
  for (label, directory) in [
    ("source device", paths.sourceDeviceDirectory), ("clone device", paths.cloneDeviceDirectory),
    ("source data", paths.sourceDataDirectory), ("clone data", paths.cloneDataDirectory),
  ] {
    var info = stat()
    guard lstat(directory, &info) == 0 else {
      throw SimSlimError("locate \(label) directory: lstat \(directory): \(errnoText())")
    }
    if kind(info) != S_IFDIR {
      throw SimSlimError("\(label) path is not a real directory: \(directory)")
    }
  }
  // The rewrite roots come from simctl; they must look like <set>/<UDID>/data
  // before anything below them is rewritten.
  for (udid, device, data) in [
    (paths.sourceUDID, paths.sourceDeviceDirectory, paths.sourceDataDirectory),
    (paths.cloneUDID, paths.cloneDeviceDirectory, paths.cloneDataDirectory),
  ] {
    let deviceName = Array(cleanPath(device).utf8.split(separator: slashByte).last ?? [])
    let dataName = Array(cleanPath(data).utf8.split(separator: slashByte).last ?? [])
    guard String(decoding: deviceName, as: UTF8.self).uppercased() == udid.uppercased(),
      String(decoding: dataName, as: UTF8.self) == "data"
    else {
      throw SimSlimError("simulator data path is not <device set>/\(udid)/data: \(data)")
    }
  }
  if cleanPath(paths.sourceDeviceDirectory) == cleanPath(paths.cloneDeviceDirectory) {
    throw SimSlimError("clone source and destination UDIDs must be distinct")
  }
  for (device, data) in [
    (paths.sourceDeviceDirectory, paths.sourceDataDirectory),
    (paths.cloneDeviceDirectory, paths.cloneDataDirectory),
  ] {
    try requireDescendant(device, data)
    try requireResolvedDescendant(device, data)
  }
}

// MARK: - Generated stores

/// Removes the named regular files from `directory` below `dataDirectory`. A
/// missing directory is fine; anything that is not a real directory or regular
/// file stops the clone rather than being followed or guessed at.
private func removeStores(
  dataDirectory: String, directory: String, what: String, matching: (String) -> Bool
) throws {
  try requireDescendant(dataDirectory, directory)
  var info = stat()
  if lstat(directory, &info) != 0 {
    if errno == ENOENT { return }
    throw SimSlimError("locate cloned \(what) data: lstat \(directory): \(errnoText())")
  }
  if kind(info) != S_IFDIR {
    throw SimSlimError("cloned \(what) path is not a real directory: \(directory)")
  }
  try requireResolvedDescendant(dataDirectory, directory)
  for entry in try readDirectory(directory) where matching(entry.name) {
    let target = join(directory, entry.name)
    try requireDescendant(directory, target)
    var targetInfo = stat()
    if lstat(target, &targetInfo) != 0 {
      if errno == ENOENT { continue }
      throw SimSlimError("inspect cloned \(what) store: lstat \(target): \(errnoText())")
    }
    if kind(targetInfo) != S_IFREG {
      throw SimSlimError("cloned \(what) store is not a regular file: \(target)")
    }
    if unlink(target) != 0 {
      throw SimSlimError("reset cloned \(what) store: remove \(target): \(errnoText())")
    }
  }
}

func resetClonedLaunchServices(dataDirectory: String) throws {
  try removeStores(
    dataDirectory: dataDirectory, directory: join(join(dataDirectory, "var"), "db/lsd"),
    what: "LaunchServices"
  ) { $0.hasPrefix("com.apple.LaunchServices-") && $0.contains(".csstore") }
}

func resetClonedFrontBoard(dataDirectory: String) throws {
  let names: Set<String> = [
    "applicationState.db", "applicationState.db-shm", "applicationState.db-wal",
  ]
  try removeStores(
    dataDirectory: dataDirectory, directory: join(join(dataDirectory, "Library"), "FrontBoard"),
    what: "FrontBoard"
  ) { names.contains($0) }
}

/// Clears system-owned indexes, task databases and asset registries that keep
/// absolute simulator paths outside property lists. Their daemons regenerate
/// them; installed apps, app data and downloaded MobileAsset payloads are not on
/// this list.
func resetClonedGeneratedPathState(dataDirectory: String) throws {
  func at(_ parts: String...) -> String { parts.reduce(dataDirectory) { join($0, $1) } }
  var directories = [
    at("Library", "AppleMediaServices", "Engagement", "internal", "database"),
    at("Library", "Spotlight"),
    at("Library", "chronod", "replicator"),
    at("Library", "com.apple.nsurlsessiond"),
    at("private", "var", "MobileAsset", "AssetsV2", "locks"),
    at("private", "var", "MobileAsset", "AssetsV2", "persisted"),
    at("private", "var", "db", "assetsubscriptiond", "history"),
    at("var", "db", "diagnostics", "Persist"),
    at("var", "db", "diagnostics", "Special"),
  ]
  // One `replicatord` per app group. A group that is a symlink is not listed
  // here but is not skipped either: its target is rejected by the cleanup check.
  let groups = at("Containers", "Shared", "AppGroup")
  var groupInfo = stat()
  if lstat(groups, &groupInfo) == 0 {
    if kind(groupInfo) == S_IFDIR {
      for entry in try readDirectory(groups) {
        let target = join(join(groups, entry.name), "replicatord")
        var info = stat()
        if lstat(target, &info) != 0 && (errno == ENOENT || errno == ENOTDIR) { continue }
        directories.append(target)
      }
    } else {
      throw SimSlimError("locate cloned replicator state: \(groups) is not a real directory")
    }
  } else if errno != ENOENT && errno != ENOTDIR {
    throw SimSlimError("locate cloned replicator state: lstat \(groups): \(errnoText())")
  }
  for directory in directories {
    do {
      try clearDirectoryContents(dataDirectory: dataDirectory, target: directory)
    } catch {
      throw SimSlimError(
        "reset cloned generated path state \(directory): \(error.localizedDescription)")
    }
  }
}

// MARK: - Rebasing

private func replaceAll(in data: Data, _ needle: Data, with replacement: Data) -> Data? {
  guard data.range(of: needle) != nil else { return nil }
  var out = Data()
  var rest = data[...]
  while let found = rest.range(of: needle) {
    out.append(rest[rest.startIndex..<found.lowerBound])
    out.append(replacement)
    rest = rest[found.upperBound...]
  }
  out.append(rest)
  return out
}

/// Replaces `path` with `contents` through a private temporary file in the same
/// directory, keeping the permission bits.
private func replaceRegularFile(_ path: String, contents: Data, mode: mode_t) throws {
  let temporary = join(directoryName(path), ".simslim-rebase-\(UUID().uuidString)")
  let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
  guard fd >= 0 else { throw SimSlimError("open \(temporary): \(errnoText())") }
  var finished = false
  defer {
    close(fd)
    if !finished { unlink(temporary) }
  }
  guard fchmod(fd, mode & 0o777) == 0 else { throw SimSlimError("chmod: \(errnoText())") }
  var offset = 0
  try contents.withUnsafeBytes { raw in
    while offset < raw.count {
      let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
      if n < 0 {
        if errno == EINTR { continue }
        throw SimSlimError("write \(temporary): \(errnoText())")
      }
      offset += n
    }
  }
  guard fsync(fd) == 0 else { throw SimSlimError("sync \(temporary): \(errnoText())") }
  guard rename(temporary, path) == 0 else { throw SimSlimError("rename: \(errnoText())") }
  finished = true
}

/// Property lists often store simulator-local file URLs (wallpaper is the usual
/// example). The two UDIDs have the same byte length, so swapping one for the
/// other keeps both XML and binary plists valid and points the setting at the clone.
func rebaseClonePropertyLists(_ paths: CloneFilesystem) throws {
  guard paths.sourceUDID.utf8.count == paths.cloneUDID.utf8.count else {
    throw SimSlimError("source and clone UDIDs must have equal lengths")
  }
  let source = Data(paths.sourceUDID.utf8)
  let clone = Data(paths.cloneUDID.utf8)
  try walkTree(paths.cloneDeviceDirectory, skippingVanished: true) { path, info in
    guard kind(info) == S_IFREG, path.lowercased().hasSuffix(".plist") else { return .descend }
    let contents: Data
    do {
      contents = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw SimSlimError(
        "read cloned property list \(path): \(error.localizedDescription)")
    }
    guard let rebased = replaceAll(in: contents, source, with: clone) else { return .descend }
    do {
      try replaceRegularFile(path, contents: rebased, mode: info.st_mode)
    } catch {
      throw SimSlimError(
        "rebase cloned property list \(path): \(error.localizedDescription)")
    }
    return .descend
  }
}

private func replaceSymlink(_ path: String, target: String) throws {
  let temporary = join(directoryName(path), ".simslim-relink-\(UUID().uuidString)")
  guard symlink(target, temporary) == 0 else { throw SimSlimError(errnoText()) }
  guard rename(temporary, path) == 0 else {
    let message = errnoText()
    unlink(temporary)
    throw SimSlimError(message)
  }
}

/// Points every symlink in the clone that resolves into the source device (or its
/// log directory) at the same place in the clone. Relative links stay relative.
func rebaseCloneSymlinks(_ paths: CloneFilesystem) throws {
  try walkTree(paths.cloneDeviceDirectory, skippingVanished: true) { path, info in
    guard kind(info) == S_IFLNK else { return .descend }
    let target: String
    do { target = try readLink(path) } catch {
      throw SimSlimError("read cloned symlink \(path): \(error.localizedDescription)")
    }
    let resolved = resolvedLinkTarget(path, target)
    guard
      let mapped = rebasePath(
        resolved, sourceRoot: paths.sourceDeviceDirectory, cloneRoot: paths.cloneDeviceDirectory)
        ?? rebasePath(
          resolved, sourceRoot: paths.sourceLogDirectory, cloneRoot: paths.cloneLogDirectory)
    else { return .descend }
    let replacement =
      target.utf8.first == slashByte ? mapped : relativePath(from: directoryName(path), to: mapped)
    do {
      try replaceSymlink(path, target: replacement)
    } catch {
      throw SimSlimError("rebase cloned symlink \(path): \(error.localizedDescription)")
    }
    return .descend
  }
}

// MARK: - Independence check

/// Fails if anything in the clone still reaches the source: a symlink into the
/// source device or naming its UDID, or a regular file that is the very same
/// file (a hard link) as its counterpart in the source.
func verifyCloneIndependence(_ paths: CloneFilesystem) throws {
  try walkTree(paths.cloneDeviceDirectory, skippingVanished: true) { path, info in
    if kind(info) == S_IFLNK {
      let target: String
      do { target = try readLink(path) } catch {
        throw SimSlimError("read cloned symlink \(path): \(error.localizedDescription)")
      }
      let resolved = resolvedLinkTarget(path, target)
      if rebasePath(
        resolved, sourceRoot: paths.sourceDeviceDirectory, cloneRoot: paths.cloneDeviceDirectory)
        != nil || pathContainsComponent(resolved, paths.sourceUDID)
        || pathContainsComponent(target, paths.sourceUDID)
      {
        throw SimSlimError(
          "cloned symlink \(path) still resolves into the source simulator: \(target)")
      }
      return .descend
    }
    guard kind(info) == S_IFREG else { return .descend }

    let prefix = cleanPath(paths.cloneDeviceDirectory)
    let relative = Array(cleanPath(path).utf8).dropFirst(prefix.utf8.count + 1)
    let sourcePath = join(paths.sourceDeviceDirectory, String(decoding: relative, as: UTF8.self))
    var sourceInfo = stat()
    if lstat(sourcePath, &sourceInfo) != 0 {
      if errno == ENOENT || errno == ENOTDIR { return .descend }
      throw SimSlimError("inspect source counterpart \(sourcePath): \(errnoText())")
    }
    if kind(sourceInfo) == S_IFREG && sourceInfo.st_dev == info.st_dev
      && sourceInfo.st_ino == info.st_ino
    {
      throw SimSlimError("cloned file \(path) is hard-linked to the source simulator")
    }
    return .descend
  }
}

/// Rebuilds a raw clone's path-bearing state so it no longer points into its
/// source, then proves it.
func sanitizeClonedDevice(_ paths: CloneFilesystem) throws {
  try validateCloneFilesystem(paths)
  // Regenerating only these system copies keeps app bundles, app data, settings
  // and app-owned caches while dropping stale absolute paths.
  try resetClonedLaunchServices(dataDirectory: paths.cloneDataDirectory)
  try resetClonedFrontBoard(dataDirectory: paths.cloneDataDirectory)
  try resetClonedGeneratedPathState(dataDirectory: paths.cloneDataDirectory)
  for directory in [
    join(join(paths.cloneDataDirectory, "Library"), "Caches"),
    join(paths.cloneDataDirectory, "tmp"),
  ] {
    do {
      try clearDirectoryContents(dataDirectory: paths.cloneDataDirectory, target: directory)
    } catch {
      throw SimSlimError("reset cloned transient state: \(error.localizedDescription)")
    }
  }
  try rebaseClonePropertyLists(paths)
  try rebaseCloneSymlinks(paths)
  try verifyCloneIndependence(paths)
}
