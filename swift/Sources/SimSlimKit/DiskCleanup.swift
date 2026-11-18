import Foundation

// Disk measurement and the permanent disk cleanup. Deletion is tightly confined:
// only allowlisted, name-matched directories inside a simulator's own data
// directory are ever emptied, symlinks are never followed, and the shared signed
// runtime (built-in apps, core OS resources) is out of reach by construction.

/// One tightly allowlisted class of per-device data. Runtime files are
/// deliberately outside this model: an iOS runtime is shared by many simulators
/// and must only be managed by Xcode/simctl.
public struct DiskCleanupCategory: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let downside: String
  public let recovery: String
  public let risk: String
  public let defaultSelected: Bool
  public let canClean: Bool
}

public let diskCleanupCategories: [DiskCleanupCategory] = [
  DiskCleanupCategory(
    id: "caches", name: "System & App Caches",
    description: "Generated cache files belonging to iOS and installed apps.",
    downside: "Next launches may be slower; downloaded or offline cache content can disappear.",
    recovery: "Old cache contents stay deleted; apps build new caches as needed.",
    risk: "Lower risk", defaultSelected: true, canClean: true),
  DiskCleanupCategory(
    id: "logs", name: "Logs & Diagnostics",
    description: "Unified logs, signposts, symbol text, crash logs, and app log folders.",
    downside: "Existing diagnostic and crash history is deleted.",
    recovery: "Old history stays deleted; future runs create new logs.",
    risk: "Lower risk", defaultSelected: true, canClean: true),
  DiskCleanupCategory(
    id: "temporary", name: "Temporary Files",
    description: "Files in simulator and app temporary directories.",
    downside: "Apps that misuse temporary storage may lose in-progress work.",
    recovery: "Old contents stay deleted; apps create new temporary files as needed.",
    risk: "Lower risk", defaultSelected: true, canClean: true),
  DiskCleanupCategory(
    id: "linguistic-data", name: "Downloaded Language Data",
    description: "On-demand language models used by Siri, Search, and text analysis.",
    downside: "Language-aware features may be limited until iOS downloads the package again.",
    recovery: "iOS downloads the language package again when a feature needs it.",
    risk: "Restored on demand", defaultSelected: false, canClean: true),
  DiskCleanupCategory(
    id: "required-siri-assets", name: "Required Siri Assets",
    description: "Siri understanding, speech, voice, and accessibility downloads restored by iOS.",
    downside: "Manual deletion is unsupported, and iOS promptly downloads required assets again.",
    recovery: "Required assets return automatically after boot.",
    risk: "System managed", defaultSelected: false, canClean: false),
]

/// A read-only breakdown of durable per-simulator storage. These rows are
/// deliberately separate from cleanup categories so documents, app bundles, and
/// user data can never become selected for deletion.
public struct DiskStorageMeasurement: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public var bytes: Int64
}

let diskStorageCategories: [DiskStorageMeasurement] = [
  DiskStorageMeasurement(
    id: "installed-apps", name: "Installed Apps",
    description:
      "Developer-installed app and test-runner bundles. Built-in apps live in the shared runtime.",
    bytes: 0),
  DiskStorageMeasurement(
    id: "documents", name: "Documents",
    description: "Files in app and app-group Documents directories.", bytes: 0),
  DiskStorageMeasurement(
    id: "app-data", name: "App Data",
    description:
      "Preferences, databases, and support files outside Documents and cleanup categories.",
    bytes: 0),
  DiskStorageMeasurement(
    id: "user-media", name: "User Media",
    description:
      "Photos, videos, downloads, and other files in the simulator media library.", bytes: 0),
]

/// A category plus what it currently holds. The category's fields are flattened
/// into the same JSON object, as in the Go output.
public struct DiskCleanupCategoryMeasurement: Codable, Equatable, Sendable {
  public var category: DiskCleanupCategory
  public var bytes: Int64
  public var targets: Int

  private enum ExtraKeys: String, CodingKey { case bytes, targets }

  public func encode(to encoder: Encoder) throws {
    try category.encode(to: encoder)
    var c = encoder.container(keyedBy: ExtraKeys.self)
    try c.encode(bytes, forKey: .bytes)
    try c.encode(targets, forKey: .targets)
  }

  public init(category: DiskCleanupCategory, bytes: Int64, targets: Int) {
    self.category = category
    self.bytes = bytes
    self.targets = targets
  }

  public init(from decoder: Decoder) throws {
    category = try DiskCleanupCategory(from: decoder)
    let c = try decoder.container(keyedBy: ExtraKeys.self)
    bytes = try c.decode(Int64.self, forKey: .bytes)
    targets = try c.decode(Int.self, forKey: .targets)
  }
}

public struct DiskCleanupPlan: Codable, Equatable, Sendable {
  public var udid: String
  public var totalBytes: Int64 = 0
  public var cleanableBytes: Int64 = 0
  public var categories: [DiskCleanupCategoryMeasurement] = []
  public var storage: [DiskStorageMeasurement] = []
}

public struct DiskCleanupResult: Codable, Equatable, Sendable {
  public var udid: String
  public var categoryIds: [String]
  public var beforeBytes: Int64
  public var afterBytes: Int64
  public var reclaimedBytes: Int64
  public var wasBooted: Bool = false
  public var bootStateRestored: Bool = false
}

/// The `size` command's result.
public struct DiskMeasurement: Codable, Equatable, Sendable {
  public var bytes: Int64
  public init(bytes: Int64) { self.bytes = bytes }
}

func diskCleanupCategory(id: String) -> DiskCleanupCategory? {
  diskCleanupCategories.first { $0.id == id }
}

/// Checks and normalises a selection: blanks and repeats dropped, unknown or
/// measure-only categories refused, at least one required, sorted.
public func validateDiskCleanupSelection(_ ids: [String]) throws -> [String] {
  var seen = Set<String>()
  var validated: [String] = []
  for raw in ids {
    let id = goTrimSpace(raw)
    if id.isEmpty || seen.contains(id) { continue }
    guard let category = diskCleanupCategory(id: id) else {
      throw SimSlimError("unknown disk cleanup category \(goQuote(id))")
    }
    if !category.canClean {
      throw SimSlimError(
        "disk cleanup category \(goQuote(id)) is measured only and cannot be cleaned")
    }
    seen.insert(id)
    validated.append(id)
  }
  if validated.isEmpty { throw SimSlimError("select at least one cleanable disk category") }
  return validated.sorted()
}

// MARK: - Paths

/// Lexical path cleaning, like Go's `filepath.Clean`. It works on bytes: Swift's
/// Character view would merge a name that starts with a combining mark with the
/// slash before it.
func cleanPath(_ path: String) -> String {
  let bytes = Array(path.utf8)
  if bytes.isEmpty { return "." }
  let slash = UInt8(ascii: "/")
  let dot = UInt8(ascii: ".")
  let rooted = bytes[0] == slash
  var parts: [[UInt8]] = []
  for part in bytes.split(separator: slash, omittingEmptySubsequences: true) {
    if part.elementsEqual([dot]) { continue }
    if part.elementsEqual([dot, dot]) {
      if let last = parts.last, !last.elementsEqual([dot, dot]) {
        parts.removeLast()
      } else if !rooted {
        parts.append(Array(part))
      }
      continue
    }
    parts.append(Array(part))
  }
  var out: [UInt8] = rooted ? [slash] : []
  for (index, part) in parts.enumerated() {
    if index > 0 { out.append(slash) }
    out.append(contentsOf: part)
  }
  if out.isEmpty { return "." }
  return String(decoding: out, as: UTF8.self)
}

/// Whether `target` is strictly inside `root` (neither equal to it nor outside),
/// judged on the cleaned paths alone, byte by byte.
func isStrictDescendant(_ root: String, _ target: String) -> Bool {
  let root = Array(cleanPath(root).utf8)
  let target = Array(cleanPath(target).utf8)
  if root == target { return false }
  let slash = UInt8(ascii: "/")
  let prefix = root == [slash] ? root : root + [slash]
  return target.count > prefix.count && target.starts(with: prefix)
}

func requireDescendant(_ root: String, _ target: String) throws {
  guard isStrictDescendant(root, target) else {
    throw SimSlimError("refusing cleanup path outside simulator data: \(cleanPath(target))")
  }
}

/// The real path with every symlink resolved, like Go's `filepath.EvalSymlinks`.
func resolvedPath(_ path: String) throws -> String {
  guard let resolved = realpath(path, nil) else {
    throw SimSlimError(String(cString: strerror(errno)))
  }
  defer { free(resolved) }
  return String(cString: resolved)
}

/// Rejects a target unless its real path is exactly where its own path says it
/// is, below the real root: no symlink may sit anywhere on the way down. Checking
/// only that the real path stays inside the root would let a symlink within the
/// data directory (say `var -> Media`) redirect a fixed cleanup path such as
/// `var/log` into protected user data.
func requireResolvedDescendant(_ root: String, _ target: String) throws {
  let resolvedRoot: String
  do {
    resolvedRoot = try resolvedPath(root)
  } catch {
    throw SimSlimError("resolve cleanup root: \(error.localizedDescription)")
  }
  let resolvedTarget: String
  do {
    resolvedTarget = try resolvedPath(target)
  } catch {
    throw SimSlimError("resolve cleanup target: \(error.localizedDescription)")
  }
  guard isStrictDescendant(resolvedRoot, resolvedTarget) else {
    throw SimSlimError(
      "refusing symlinked cleanup path \(target): refusing cleanup path outside simulator data: \(cleanPath(resolvedTarget))"
    )
  }
  // Where the path says the target is: the real root plus the relative part.
  let lexicalRoot = Array(cleanPath(root).utf8)
  let lexicalTarget = Array(cleanPath(target).utf8)
  let relative = lexicalTarget.dropFirst(
    lexicalRoot == [UInt8(ascii: "/")] ? 1 : lexicalRoot.count + 1)
  let expected = join(resolvedRoot, String(decoding: relative, as: UTF8.self))
  guard Array(cleanPath(resolvedTarget).utf8) == Array(cleanPath(expected).utf8) else {
    throw SimSlimError(
      "refusing symlinked cleanup path \(target): it resolves to \(cleanPath(resolvedTarget)), not inside the data directory at \(cleanPath(expected))"
    )
  }
}

private func join(_ directory: String, _ name: String) -> String {
  directory.hasSuffix("/") ? directory + name : directory + "/" + name
}

private func join(_ root: String, _ names: String...) -> String {
  names.reduce(root) { join($0, $1) }
}

// MARK: - Walking

private enum WalkStep { case descend, skip }

private func lstatInfo(_ path: String) throws -> stat {
  var info = stat()
  guard lstat(path, &info) == 0 else {
    throw SimSlimError("lstat \(path): \(String(cString: strerror(errno)))")
  }
  return info
}

private func isDirectory(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }

/// One directory entry as `readdir` reports it. `isDirectory` is the entry's own
/// type (a symlink to a directory is not one), or nil when the filesystem did not
/// say.
struct DirectoryEntry {
  var name: String
  var isDirectory: Bool?
}

/// Lists a directory with `readdir`, sorted by name like Go's `os.ReadDir`.
/// Foundation's `contentsOfDirectory` silently omits AppleDouble `._*` files,
/// which a cleanup must not leave behind or leave unmeasured.
func readDirectory(_ path: String) throws -> [DirectoryEntry] {
  guard let dir = opendir(path) else {
    throw SimSlimError("read \(path): \(String(cString: strerror(errno)))")
  }
  defer { closedir(dir) }
  var entries: [DirectoryEntry] = []
  while let entry = readdir(dir) {
    let name = withUnsafePointer(to: &entry.pointee.d_name) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
    }
    if name == "." || name == ".." { continue }
    let type: Bool? =
      entry.pointee.d_type == UInt8(DT_UNKNOWN) ? nil : entry.pointee.d_type == UInt8(DT_DIR)
    entries.append(DirectoryEntry(name: name, isDirectory: type))
  }
  return entries.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
}

/// Visits `root` and everything below it in lexical order, never following a
/// symlink (a symlink is an entry, not a directory). Every entry is `lstat`ed, so a
/// file that vanishes mid-walk is an error, as in Go's `filepath.WalkDir` +
/// `entry.Info()`. Used where sizes are summed.
private func walkTree(_ root: String, _ visit: (String, stat) throws -> WalkStep) throws {
  func walk(_ path: String, _ info: stat) throws {
    let step = try visit(path, info)
    guard isDirectory(info), step == .descend else { return }
    for entry in try readDirectory(path) {
      let child = join(path, entry.name)
      try walk(child, try lstatInfo(child))
    }
  }
  try walk(root, try lstatInfo(root))
}

/// Test seam: walks like discovery does and calls `visit` for each directory.
func walkDirectoriesForTest(_ root: String, _ visit: (String) throws -> Bool) throws {
  try walkDirectories(root) { try visit($0) ? .descend : .skip }
}

/// Visits the directories below `root` using only the type `readdir` reports, so
/// the churn of a running simulator (a file created and deleted between listing
/// and looking) cannot fail discovery. A subdirectory that vanishes is skipped.
private func walkDirectories(_ root: String, _ visit: (String) throws -> WalkStep) throws {
  func walk(_ path: String) throws {
    let entries: [DirectoryEntry]
    do {
      entries = try readDirectory(path)
    } catch {
      var info = stat()
      if lstat(path, &info) != 0 && errno == ENOENT { return }
      throw error
    }
    for entry in entries {
      let child = join(path, entry.name)
      var isDir = entry.isDirectory
      if isDir == nil {  // the filesystem did not say
        var info = stat()
        guard lstat(child, &info) == 0 else { continue }
        isDir = (info.st_mode & S_IFMT) == S_IFDIR
      }
      guard isDir == true else { continue }
      if try visit(child) == .descend { try walk(child) }
    }
  }
  try walk(root)
}

/// Allocated bytes (filesystem blocks, like `du`) of everything under `root`,
/// including `root` itself.
func allocatedSize(_ root: String) throws -> Int64 {
  var total: Int64 = 0
  try walkTree(root) { _, info in
    total += Int64(info.st_blocks) * 512
    return .descend
  }
  return total
}

func allocatedSizeExcludingNames(_ root: String, excluded: Set<String>) throws -> Int64 {
  var total: Int64 = 0
  try walkTree(root) { path, info in
    if path != root, isDirectory(info), excluded.contains((path as NSString).lastPathComponent) {
      return .skip
    }
    total += Int64(info.st_blocks) * 512
    return .descend
  }
  return total
}

/// Durable user content and system-managed assets stay out of name-based
/// discovery. An app may legitimately create a folder named Caches, Logs, or tmp
/// below Documents; its name alone does not make that content disposable.
func isProtectedCleanupSubtree(_ name: String) -> Bool {
  ["Documents", "Mobile Documents", "Media", "MobileAsset"].contains(name)
}

func findNamedDirectories(root: String, name: String, excludedAncestors: Set<String>) throws
  -> [String]
{
  var targets: [String] = []
  let bundleDirectory = join(root, "Containers", "Bundle")
  try walkDirectories(root) { path in
    let entryName = (path as NSString).lastPathComponent
    // Packaged resources are durable even when named Caches, Logs, or tmp.
    if path == bundleDirectory { return .skip }
    if isProtectedCleanupSubtree(entryName) { return .skip }
    if excludedAncestors.contains(entryName) { return .skip }
    if entryName == name {
      targets.append(path)
      return .skip
    }
    return .descend
  }
  return targets
}

/// The existing real directories among `candidates`, each confined to `root`,
/// with any that sit inside another dropped so nothing is counted or cleared twice.
func compactExistingTargets(_ root: String, _ candidates: [String]) throws -> [String] {
  var unique = Set<String>()
  var targets: [String] = []
  for raw in candidates {
    let candidate = cleanPath(raw)
    try requireDescendant(root, candidate)
    var info = stat()
    if lstat(candidate, &info) != 0 {
      if errno == ENOENT { continue }
      throw SimSlimError("lstat \(candidate): \(String(cString: strerror(errno)))")
    }
    // A symlink, or anything that is not a directory, is never a target.
    if !isDirectory(info) || unique.contains(candidate) { continue }
    try requireResolvedDescendant(root, candidate)
    unique.insert(candidate)
    targets.append(candidate)
  }
  targets.sort { a, b in a.count != b.count ? a.count < b.count : a < b }
  var compacted: [String] = []
  for target in targets where !compacted.contains(where: { isStrictDescendant($0, target) }) {
    compacted.append(target)
  }
  return compacted
}

func linguisticDataTargets(_ dataDirectory: String) throws -> [String] {
  let target = join(
    dataDirectory, "private", "var", "MobileAsset", "AssetsV2",
    "com_apple_MobileAsset_LinguisticData")
  return try compactExistingTargets(dataDirectory, [target])
}

func requiredSiriAssetTargets(_ dataDirectory: String) throws -> [String] {
  let assetsRoot = join(dataDirectory, "private", "var", "MobileAsset", "AssetsV2")
  let names: [String]
  do {
    names = try readDirectory(assetsRoot).map(\.name)
  } catch {
    var info = stat()
    if lstat(assetsRoot, &info) != 0 && errno == ENOENT { return [] }
    throw error
  }
  let prefixes = [
    "com_apple_MobileAsset_UAF_Siri_", "com_apple_MobileAsset_TTS",
    "com_apple_MobileAsset_VoiceServices_", "com_apple_MobileAsset_VoiceTrigger",
  ]
  var targets: [String] = []
  for name in names {
    let path = join(assetsRoot, name)
    guard let info = try? lstatInfo(path), isDirectory(info) else { continue }
    if prefixes.contains(where: { name.hasPrefix($0) }) { targets.append(path) }
  }
  return targets
}

func diskCleanupTargets(dataDirectory: String, categoryID: String) throws -> [String] {
  var targets: [String]
  switch categoryID {
  case "caches":
    targets = try findNamedDirectories(root: dataDirectory, name: "Caches", excludedAncestors: [])
  case "temporary":
    targets = try findNamedDirectories(
      root: dataDirectory, name: "tmp", excludedAncestors: ["Caches"])
  case "logs":
    targets = [
      join(dataDirectory, "Library", "Logs"),
      join(dataDirectory, "var", "log"),
      join(dataDirectory, "var", "db", "diagnostics"),
      join(dataDirectory, "var", "db", "uuidtext"),
    ]
    targets += try findNamedDirectories(
      root: dataDirectory, name: "Logs", excludedAncestors: ["Caches", "tmp"])
  case "linguistic-data":
    targets = try linguisticDataTargets(dataDirectory)
  case "required-siri-assets":
    targets = try requiredSiriAssetTargets(dataDirectory)
  default:
    throw SimSlimError("unknown disk cleanup category \(goQuote(categoryID))")
  }
  return try compactExistingTargets(dataDirectory, targets)
}

// MARK: - Storage breakdown (read only)

func allocatedSizeOfExistingDirectories(_ root: String, _ candidates: [String]) throws -> Int64 {
  try compactExistingTargets(root, candidates).reduce(0) { try $0 + allocatedSize($1) }
}

private func containerRoots(_ dataDirectory: String) -> [String] {
  [
    join(dataDirectory, "Containers", "Data", "Application"),
    join(dataDirectory, "Containers", "Shared", "AppGroup"),
  ]
}

func appDocumentTargets(_ dataDirectory: String) throws -> [String] {
  var candidates: [String] = []
  for root in containerRoots(dataDirectory) {
    let names: [String]
    do {
      names = try readDirectory(root).map(\.name)
    } catch {
      var info = stat()
      if lstat(root, &info) != 0 && errno == ENOENT { continue }
      throw error
    }
    for name in names {
      let path = join(root, name)
      if let info = try? lstatInfo(path), isDirectory(info) {
        candidates.append(join(path, "Documents"))
      }
    }
  }
  return try compactExistingTargets(dataDirectory, candidates)
}

func appDataSize(_ dataDirectory: String) throws -> Int64 {
  let excluded: Set<String> = ["Caches", "Documents", "Logs", "tmp"]
  var total: Int64 = 0
  for root in containerRoots(dataDirectory) {
    var info = stat()
    if lstat(root, &info) != 0 {
      if errno == ENOENT { continue }
      throw SimSlimError("lstat \(root): \(String(cString: strerror(errno)))")
    }
    if !isDirectory(info) { continue }  // a symlink or file is skipped, never followed
    try requireResolvedDescendant(dataDirectory, root)
    total += try allocatedSizeExcludingNames(root, excluded: excluded)
  }
  return total
}

func diskStorageMeasurements(_ dataDirectory: String) throws -> [DiskStorageMeasurement] {
  try diskStorageCategories.map { category in
    var measurement = category
    do {
      switch category.id {
      case "installed-apps":
        measurement.bytes = try allocatedSizeOfExistingDirectories(
          dataDirectory, [join(dataDirectory, "Containers", "Bundle", "Application")])
      case "documents":
        measurement.bytes = try allocatedSizeOfExistingDirectories(
          dataDirectory, try appDocumentTargets(dataDirectory))
      case "app-data":
        measurement.bytes = try appDataSize(dataDirectory)
      case "user-media":
        measurement.bytes = try allocatedSizeOfExistingDirectories(
          dataDirectory, [join(dataDirectory, "Media")])
      default:
        throw SimSlimError("unknown disk storage category \(goQuote(category.id))")
      }
    } catch {
      throw SimSlimError("measure \(category.name): \(error.localizedDescription)")
    }
    return measurement
  }
}

// MARK: - Plan and clean

func diskCleanupPlan(udid: String, dataDirectory: String) throws -> DiskCleanupPlan {
  var plan = DiskCleanupPlan(udid: udid)
  for category in diskCleanupCategories {
    let targets: [String]
    do {
      targets = try diskCleanupTargets(dataDirectory: dataDirectory, categoryID: category.id)
    } catch {
      throw SimSlimError("scan \(category.name): \(error.localizedDescription)")
    }
    var measurement = DiskCleanupCategoryMeasurement(
      category: category, bytes: 0, targets: targets.count)
    for target in targets {
      do {
        measurement.bytes += try allocatedSize(target)
      } catch {
        throw SimSlimError("measure \(target): \(error.localizedDescription)")
      }
    }
    plan.totalBytes += measurement.bytes
    if category.canClean { plan.cleanableBytes += measurement.bytes }
    plan.categories.append(measurement)
  }
  plan.storage = try diskStorageMeasurements(dataDirectory)
  return plan
}

private func selectedCleanupBytes(_ plan: DiskCleanupPlan, _ ids: [String]) -> Int64 {
  plan.categories.filter { ids.contains($0.category.id) }.reduce(0) { $0 + $1.bytes }
}

/// Empties one allowlisted directory: every immediate child is removed, the
/// directory itself stays. The target must be a real directory (never a symlink)
/// that resolves inside the data directory, and so must every child path.
func clearDirectoryContents(dataDirectory: String, target: String) throws {
  try requireDescendant(dataDirectory, target)
  var info = stat()
  if lstat(target, &info) != 0 {
    if errno == ENOENT { return }
    throw SimSlimError("lstat \(target): \(String(cString: strerror(errno)))")
  }
  if !isDirectory(info) {
    throw SimSlimError("refusing to clear non-directory target \(target)")
  }
  try requireResolvedDescendant(dataDirectory, target)
  let names = try readDirectory(target).map(\.name)
  for name in names {
    let child = join(target, name)
    try requireDescendant(dataDirectory, child)
    try removeIfPresent(child)
  }
}

/// Removes one entry. A symlink is unlinked, never followed, and a mount point
/// is not crossed. An entry that is already gone (a running simulator cleaning up
/// after itself) is the state we wanted, so it is not an error.
func removeIfPresent(_ path: String) throws {
  do {
    try FileManager.default.removeItem(atPath: path)
  } catch {
    var info = stat()
    if lstat(path, &info) != 0 && errno == ENOENT { return }
    throw SimSlimError("remove \(path): \(error.localizedDescription)")
  }
}

func cleanDisk(udid: String, dataDirectory: String, categoryIDs requested: [String]) throws
  -> DiskCleanupResult
{
  let categoryIDs = try validateDiskCleanupSelection(requested)
  let beforePlan = try diskCleanupPlan(udid: udid, dataDirectory: dataDirectory)
  let beforeBytes = selectedCleanupBytes(beforePlan, categoryIDs)

  for id in categoryIDs {
    for target in try diskCleanupTargets(dataDirectory: dataDirectory, categoryID: id) {
      do {
        try clearDirectoryContents(dataDirectory: dataDirectory, target: target)
      } catch {
        throw SimSlimError("clean \(target): \(error.localizedDescription)")
      }
    }
  }

  let afterPlan = try diskCleanupPlan(udid: udid, dataDirectory: dataDirectory)
  let afterBytes = selectedCleanupBytes(afterPlan, categoryIDs)
  return DiskCleanupResult(
    udid: udid, categoryIds: categoryIDs, beforeBytes: beforeBytes, afterBytes: afterBytes,
    reclaimedBytes: max(0, beforeBytes - afterBytes))
}

extension Simctl {
  /// Measures what could be cleaned and the durable storage that never will be.
  /// The UDID is resolved through simctl first, so an alias such as `all` can
  /// never become a filesystem path.
  public func planDiskCleanup(udid: String) throws -> DiskCleanupPlan {
    let (_, dataDirectory) = try simulatorDataDirectory(udid: udid)
    return try diskCleanupPlan(udid: udid, dataDirectory: dataDirectory)
  }

  /// Permanently deletes the contents of the selected categories' directories. A
  /// booted simulator is shut down first, because its processes are using those
  /// files; with `preserveBootState` it is booted again afterwards.
  public func cleanDeviceDisk(
    udid: String, categoryIDs: [String], preserveBootState: Bool
  ) throws -> DiskCleanupResult {
    let (device, dataDirectory) = try simulatorDataDirectory(udid: udid)
    let categories = try validateDiskCleanupSelection(categoryIDs)

    let wasBooted = device.state == "Booted"
    // Shuts a booted simulator down, and refuses one that is Booting or Shutting
    // Down: its processes are using these files. (Go deletes under it.)
    _ = try shutdownIfBooted(udid: udid)

    var result = DiskCleanupResult(
      udid: udid, categoryIds: categories, beforeBytes: 0, afterBytes: 0, reclaimedBytes: 0)
    var cleanupError: Error?
    do {
      result = try cleanDisk(udid: udid, dataDirectory: dataDirectory, categoryIDs: categories)
    } catch {
      cleanupError = error
    }
    result.wasBooted = wasBooted
    if wasBooted && preserveBootState {
      do {
        try bootAndWait(set: device.set, udid: udid)
      } catch {
        if let cleanupError {
          throw SimSlimError(
            "\(cleanupError.localizedDescription); additionally could not restore boot state: \(error.localizedDescription)"
          )
        }
        throw SimSlimError(
          "disk cleanup finished, but could not restore boot state: \(error.localizedDescription)")
      }
      result.bootStateRestored = true
    }
    if let cleanupError { throw cleanupError }
    return result
  }
}
