// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import XCTest

@testable import SimSlimKit

final class DiskCleanupTests: XCTestCase {
  private var root = ""
  private var data = ""

  override func setUpWithError() throws {
    // Resolved, because /var is a symlink to /private/var on macOS: the code
    // under test must cope with a data directory that lives behind one.
    root = NSTemporaryDirectory() + "simslim-disk-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    data = root + "/data"
    try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(atPath: root)
  }

  private func write(_ path: String, size: Int = 4096) throws {
    try FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(count: size).write(to: URL(fileURLWithPath: path))
  }

  private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private func plan() throws -> DiskCleanupPlan {
    try diskCleanupPlan(udid: "TEST-UDID", dataDirectory: data)
  }

  // MARK: - the model

  func testCategoriesAreUniqueAndSafeByDefault() throws {
    var seen = Set<String>()
    for category in diskCleanupCategories {
      XCTAssertFalse(category.id.isEmpty)
      XCTAssertTrue(seen.insert(category.id).inserted, "duplicate \(category.id)")
      XCTAssertFalse(category.defaultSelected && !category.canClean, category.id)
    }
    XCTAssertFalse(try XCTUnwrap(diskCleanupCategory(id: "required-siri-assets")).canClean)
    let language = try XCTUnwrap(diskCleanupCategory(id: "linguistic-data"))
    XCTAssertTrue(language.canClean)
    XCTAssertFalse(language.defaultSelected, "opt-in")
  }

  func testRecoveryModelsStayDistinct() throws {
    for id in ["caches", "logs", "temporary"] {
      XCTAssertTrue(try XCTUnwrap(diskCleanupCategory(id: id)).recovery.contains("deleted"), id)
    }
    XCTAssertTrue(
      try XCTUnwrap(diskCleanupCategory(id: "required-siri-assets")).recovery.contains(
        "return automatically"))
    let language = try XCTUnwrap(diskCleanupCategory(id: "linguistic-data"))
    XCTAssertTrue(language.recovery.contains("downloads"))
    XCTAssertEqual(language.risk, "Restored on demand")
  }

  func testSelectionValidation() throws {
    XCTAssertEqual(
      try validateDiskCleanupSelection([" logs ", "caches", "logs", "", "  "]), ["caches", "logs"])
    for (ids, message) in [
      ([], "select at least one cleanable disk category"),
      ([" ", ""], "select at least one cleanable disk category"),
      (["nope"], "unknown disk cleanup category \"nope\""),
      (
        ["required-siri-assets"],
        "disk cleanup category \"required-siri-assets\" is measured only and cannot be cleaned"
      ),
      (["caches", "required-siri-assets"], "measured only"),
    ] as [([String], String)] {
      XCTAssertThrowsError(try validateDiskCleanupSelection(ids), "\(ids)") {
        XCTAssertTrue("\($0)".contains(message), "\($0)")
      }
    }
  }

  func testPathHelpers() {
    XCTAssertEqual(cleanPath("/a//b/./c/../d/"), "/a/b/d")
    XCTAssertEqual(cleanPath("a/../.."), "..")
    XCTAssertEqual(cleanPath("/.."), "/")
    XCTAssertEqual(cleanPath(""), ".")
    XCTAssertTrue(isStrictDescendant("/d", "/d/x"))
    XCTAssertTrue(isStrictDescendant("/d/", "/d/x/../y"))
    XCTAssertFalse(isStrictDescendant("/d", "/d"))
    XCTAssertFalse(isStrictDescendant("/d", "/d/"))
    XCTAssertFalse(isStrictDescendant("/d", "/"))
    XCTAssertFalse(isStrictDescendant("/d", "/d/../e"))
    XCTAssertFalse(isStrictDescendant("/d", "/dx"), "a sibling sharing a prefix is not inside")
    XCTAssertFalse(isStrictDescendant("/d/data", "/d/data/.."))
    XCTAssertTrue(isStrictDescendant("/", "/x"))
    XCTAssertFalse(isStrictDescendant("/", "/"))
  }

  func testRequireDescendantRejectsTheRootAndItsParents() throws {
    XCTAssertThrowsError(try requireDescendant(data, data))
    XCTAssertThrowsError(try requireDescendant(data, root))
    XCTAssertThrowsError(try requireDescendant(data, data + "/../x"))
    XCTAssertNoThrow(try requireDescendant(data, data + "/Library/Caches"))
  }

  // MARK: - plan and clean stay inside the allowlist

  func testPlanAndCleanStayInsideTheAllowlist() throws {
    let cache = data + "/Library/Caches"
    let temp = data + "/Containers/Data/Application/A/tmp"
    let diagnostics = data + "/var/db/diagnostics"
    let uuidtext = data + "/var/db/uuidtext"
    let assets = data + "/private/var/MobileAsset/AssetsV2"
    let siri = assets + "/com_apple_MobileAsset_UAF_Siri_Understanding"
    let linguistic = assets + "/com_apple_MobileAsset_LinguisticData"
    let unrelated = assets + "/com_apple_MobileAsset_PKITrustStore"
    let documents = data + "/Containers/Data/Application/A/Documents"
    let keep = [
      siri + "/model.bin", unrelated + "/trust.bin", documents + "/user.db",
      documents + "/Caches/keep-cache.bin", documents + "/Logs/keep-log.txt",
      documents + "/tmp/keep-temp.bin", siri + "/Caches/keep-asset-cache.bin",
    ]
    let remove = [
      cache + "/cache.bin", temp + "/temp.bin", diagnostics + "/log.tracev3",
      uuidtext + "/symbols", linguistic + "/language-model.bin",
    ]
    for path in remove + keep { try write(path, size: 16 * 1024) }

    let before = try plan()
    let byID = Dictionary(uniqueKeysWithValues: before.categories.map { ($0.category.id, $0) })
    for id in ["caches", "logs", "temporary", "linguistic-data", "required-siri-assets"] {
      XCTAssertGreaterThan(byID[id]!.bytes, 0, id)
    }
    XCTAssertGreaterThan(before.cleanableBytes, 0)
    XCTAssertGreaterThan(before.totalBytes, before.cleanableBytes)

    let result = try cleanDisk(
      udid: "TEST-UDID", dataDirectory: data,
      categoryIDs: ["temporary", "logs", "caches", "linguistic-data"])
    XCTAssertGreaterThan(result.reclaimedBytes, 0)
    XCTAssertEqual(result.categoryIds, ["caches", "linguistic-data", "logs", "temporary"])
    for path in remove { XCTAssertFalse(exists(path), "left \(path)") }
    for directory in [cache, temp, diagnostics, uuidtext, linguistic] {
      var info = stat()
      XCTAssertEqual(lstat(directory, &info), 0, "the directory itself stays: \(directory)")
    }
    for path in keep { XCTAssertTrue(exists(path), "touched \(path)") }
  }

  func testInstalledBundlesAreNeverTouched() throws {
    for (category, name) in [("caches", "Caches"), ("logs", "Logs"), ("temporary", "tmp")] {
      try? FileManager.default.removeItem(atPath: data)
      try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
      let bundle = data + "/Containers/Bundle/Application"
      let app = bundle + "/APP/Example.app"
      var resources: [String] = []
      for directory in [
        app, app + "/PlugIns/Example.appex", app + "/Frameworks/Example.framework",
      ] {
        let resource = "\(directory)/\(name)/keep.bin"
        try write(resource)
        resources.append(resource)
      }
      let target =
        category == "temporary"
        ? data + "/Containers/Data/Application/DATA/tmp"
        : data + "/Containers/Data/Application/DATA/Library/\(name)"
      let file = target + "/remove.bin"
      try write(file, size: 8192)
      let targetBytes = try allocatedSize(target)
      let bundleBytes = try allocatedSize(bundle)

      let before = try plan()
      XCTAssertEqual(before.cleanableBytes, targetBytes, category)
      XCTAssertEqual(before.categories.first { $0.category.id == category }?.targets, 1, category)
      XCTAssertEqual(before.storage.first { $0.id == "installed-apps" }?.bytes, bundleBytes)

      _ = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: [category])
      for resource in resources { XCTAssertTrue(exists(resource), "touched \(resource)") }
      XCTAssertFalse(exists(file), category)
      var info = stat()
      XCTAssertEqual(lstat(target, &info), 0)
    }
  }

  func testAnIntermediateSymlinkIsRejectedAndNothingOutsideIsTouched() throws {
    let outsideFile = root + "/outside/log/keep.log"
    try write(outsideFile)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/var", withDestinationPath: root + "/outside")
    XCTAssertThrowsError(try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["logs"]))
    XCTAssertTrue(exists(outsideFile))
  }

  func testSymlinksInsideATargetAreRemovedNotFollowed() throws {
    let outsideFile = root + "/outside/keep.txt"
    try write(outsideFile)
    try write(data + "/Library/Caches/own.bin")
    try FileManager.default.createSymbolicLink(
      atPath: data + "/Library/Caches/link", withDestinationPath: root + "/outside")
    try FileManager.default.createSymbolicLink(
      atPath: data + "/Library/Caches/filelink", withDestinationPath: outsideFile)
    _ = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["caches"])
    XCTAssertTrue(exists(outsideFile), "a symlink was followed out of the data directory")
    XCTAssertFalse(exists(data + "/Library/Caches/link"))
    XCTAssertFalse(exists(data + "/Library/Caches/filelink"))
    XCTAssertFalse(exists(data + "/Library/Caches/own.bin"))
  }

  func testASymlinkedTargetDirectoryIsNeverACleanupTarget() throws {
    let outsideFile = root + "/outside/Caches/keep.bin"
    try write(outsideFile)
    try FileManager.default.createDirectory(
      atPath: data + "/Library", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/Library/Caches", withDestinationPath: root + "/outside/Caches")
    let before = try plan()
    XCTAssertEqual(before.categories.first { $0.category.id == "caches" }?.targets, 0)
    _ = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["caches"])
    XCTAssertTrue(exists(outsideFile))
    // The fixed log paths are directories that may be symlinks too.
    let outsideLog = root + "/outside2/log/keep.log"
    try write(outsideLog)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/var", withDestinationPath: root + "/outside2")
    XCTAssertThrowsError(try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["logs"]))
    XCTAssertTrue(exists(outsideLog))
    XCTAssertTrue(exists(outsideFile))
  }

  func testTheDataDirectoryMayLiveBehindASymlink() throws {
    // macOS temp directories are under /var -> /private/var.
    let real = root + "/real/data"
    try write(real + "/Library/Caches/x.bin")
    try FileManager.default.createSymbolicLink(
      atPath: root + "/alias", withDestinationPath: root + "/real")
    let result = try cleanDisk(
      udid: "T", dataDirectory: root + "/alias/data", categoryIDs: ["caches"])
    XCTAssertGreaterThan(result.reclaimedBytes, 0)
    XCTAssertFalse(exists(real + "/Library/Caches/x.bin"))
  }

  func testClearDirectoryContentsRefusesWhatIsNotAnInsideDirectory() throws {
    try write(data + "/Library/Caches/a.bin")
    let file = data + "/file"
    try write(file)
    XCTAssertThrowsError(try clearDirectoryContents(dataDirectory: data, target: data))
    XCTAssertThrowsError(try clearDirectoryContents(dataDirectory: data, target: root))
    XCTAssertThrowsError(try clearDirectoryContents(dataDirectory: data, target: "/"))
    XCTAssertThrowsError(try clearDirectoryContents(dataDirectory: data, target: file)) {
      XCTAssertTrue("\($0)".hasPrefix("refusing to clear non-directory target"), "\($0)")
    }
    XCTAssertThrowsError(
      try clearDirectoryContents(dataDirectory: data, target: data + "/Library/../../data"))
    XCTAssertNoThrow(try clearDirectoryContents(dataDirectory: data, target: data + "/missing"))
    XCTAssertTrue(exists(data + "/Library/Caches/a.bin"))
    XCTAssertTrue(exists(file))
  }

  func testProtectedSubtreesAreNeverSearched() throws {
    for protected in ["Documents", "Mobile Documents", "Media", "MobileAsset"] {
      try write("\(data)/\(protected)/Caches/keep.bin")
      try write("\(data)/\(protected)/x/Logs/keep.bin")
      try write("\(data)/\(protected)/x/tmp/keep.bin")
    }
    let p = try plan()
    for measurement in p.categories
    where ["caches", "logs", "temporary"].contains(measurement.category.id) {
      XCTAssertEqual(measurement.targets, 0, measurement.category.id)
    }
  }

  func testNamesAreExactAndTemporaryIgnoresCacheSubtrees() throws {
    try write(data + "/a/Caches/x/tmp/inner.bin")  // inside Caches: Caches owns it
    try write(data + "/a/tmp/t.bin")
    try write(data + "/a/CACHES/c.bin")  // not the name
    try write(data + "/a/Caches2/c.bin")
    let tmp = try findNamedDirectories(root: data, name: "tmp", excludedAncestors: ["Caches"])
    XCTAssertEqual(tmp, [data + "/a/tmp"])
    let caches = try findNamedDirectories(root: data, name: "Caches", excludedAncestors: [])
    XCTAssertEqual(caches, [data + "/a/Caches"])
  }

  func testNestedTargetsAreCompactedSoNothingIsCountedTwice() throws {
    try write(data + "/Library/Logs/a.log")
    try write(data + "/Library/Logs/Logs/b.log")  // Logs inside Logs
    try write(data + "/var/log/c.log")
    let targets = try diskCleanupTargets(dataDirectory: data, categoryID: "logs")
    XCTAssertEqual(Set(targets), [data + "/Library/Logs", data + "/var/log"])
    let compacted = try compactExistingTargets(
      data, [data + "/Library/Logs/Logs", data + "/Library/Logs", data + "/Library/Logs/"])
    XCTAssertEqual(compacted, [data + "/Library/Logs"])
  }

  func testCandidatesOutsideTheRootAreAnError() throws {
    XCTAssertThrowsError(try compactExistingTargets(data, [root + "/other"]))
    XCTAssertThrowsError(try compactExistingTargets(data, [data]))
    XCTAssertThrowsError(try compactExistingTargets(data, [data + "/../x"]))
  }

  func testRequiredSiriAssetsAreMeasuredButNeverCleaned() throws {
    let assets = data + "/private/var/MobileAsset/AssetsV2"
    for name in [
      "com_apple_MobileAsset_UAF_Siri_X", "com_apple_MobileAsset_TTS_Y",
      "com_apple_MobileAsset_VoiceServices_Z", "com_apple_MobileAsset_VoiceTrigger",
    ] {
      try write("\(assets)/\(name)/m.bin")
    }
    try write(assets + "/com_apple_MobileAsset_Other/m.bin")
    let p = try plan()
    let siri = try XCTUnwrap(p.categories.first { $0.category.id == "required-siri-assets" })
    XCTAssertEqual(siri.targets, 4)
    XCTAssertGreaterThan(siri.bytes, 0)
    XCTAssertEqual(p.cleanableBytes, 0, "measure-only bytes are never cleanable")
    XCTAssertThrowsError(
      try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["required-siri-assets"]))
    XCTAssertTrue(exists(assets + "/com_apple_MobileAsset_UAF_Siri_X/m.bin"))
  }

  func testCleaningWithNoDirectoriesReclaimsNothing() throws {
    let result = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["caches", "logs"])
    XCTAssertEqual(result.reclaimedBytes, 0)
    XCTAssertEqual(result.beforeBytes, 0)
    XCTAssertEqual(result.afterBytes, 0)
  }

  // MARK: - storage breakdown

  func testStorageSeparatesDurableDataFromCleanup() throws {
    let container = data + "/Containers/Data/Application/DATA-CONTAINER"
    try write(data + "/Containers/Bundle/Application/APP/Example.app/Example", size: 32 * 1024)
    try write(container + "/Documents/project.data", size: 24 * 1024)
    try write(container + "/Library/Application Support/database.sqlite", size: 20 * 1024)
    try write(container + "/Library/Caches/response.cache", size: 64 * 1024)
    try write(container + "/Library/Logs/app.log", size: 64 * 1024)
    try write(container + "/tmp/work.tmp", size: 64 * 1024)
    try write(data + "/Media/DCIM/100APPLE/photo.heic", size: 28 * 1024)

    var measurements = try diskStorageMeasurements(data)
    XCTAssertEqual(
      measurements.map(\.id), ["installed-apps", "documents", "app-data", "user-media"])
    for m in measurements { XCTAssertGreaterThan(m.bytes, 0, m.id) }
    let appDataBefore = measurements.first { $0.id == "app-data" }!.bytes

    try write(container + "/Library/Caches/larger.cache", size: 512 * 1024)
    measurements = try diskStorageMeasurements(data)
    XCTAssertEqual(
      measurements.first { $0.id == "app-data" }?.bytes, appDataBefore,
      "app-data excludes cleanable caches")
  }

  func testThePlanIncludesTheReadOnlyStorageBreakdown() throws {
    try write(data + "/Containers/Bundle/Application/APP/Example.app/Example")
    try write(data + "/Containers/Data/Application/DATA/Documents/keep.txt")
    let p = try plan()
    XCTAssertEqual(p.storage.count, diskStorageCategories.count)
    XCTAssertEqual(p.cleanableBytes, 0, "durable storage never counts as cleanable")
  }

  func testASymlinkedContainerRootIsNeverFollowed() throws {
    let outside = root + "/elsewhere/APP/Documents/big.bin"
    try write(outside, size: 100_000)
    try FileManager.default.createDirectory(
      atPath: data + "/Containers/Data", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/Containers/Data/Application", withDestinationPath: root + "/elsewhere")
    // app-data skips the symlink; the Documents measurement refuses to resolve
    // through it. Either way nothing outside is counted, and nothing is changed.
    XCTAssertEqual(try appDataSize(data), 0)
    XCTAssertThrowsError(try diskStorageMeasurements(data)) {
      XCTAssertTrue("\($0)".contains("refusing symlinked cleanup path"), "\($0)")
    }
    XCTAssertTrue(exists(outside))
  }

  func testAllocatedSizeCountsBlocksNotLength() throws {
    try write(data + "/a/one.bin", size: 1)
    let size = try allocatedSize(data + "/a")
    XCTAssertGreaterThanOrEqual(size, 4096, "a one-byte file still takes a block")
    XCTAssertEqual(size % 512, 0)
    XCTAssertEqual(
      try allocatedSizeExcludingNames(data + "/a", excluded: ["x"]), size)
    try write(data + "/a/x/big.bin", size: 100_000)
    let with = try allocatedSize(data + "/a")
    let without = try allocatedSizeExcludingNames(data + "/a", excluded: ["x"])
    XCTAssertGreaterThan(with, without)
  }

  func testJSONShapeMatchesTheGoContract() throws {
    try write(data + "/Library/Caches/a.bin")
    let plan = try plan()
    let object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
    XCTAssertEqual(
      Set(object.keys), ["udid", "totalBytes", "cleanableBytes", "categories", "storage"])
    let first = (object["categories"] as! [[String: Any]])[0]
    XCTAssertEqual(
      Set(first.keys),
      [
        "id", "name", "description", "downside", "recovery", "risk", "defaultSelected",
        "canClean", "bytes", "targets",
      ])
    let result =
      try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(
          DiskCleanupResult(
            udid: "U", categoryIds: ["caches"], beforeBytes: 2, afterBytes: 1, reclaimedBytes: 1)))
      as! [String: Any]
    XCTAssertEqual(
      Set(result.keys),
      [
        "udid", "categoryIds", "beforeBytes", "afterBytes", "reclaimedBytes", "wasBooted",
        "bootStateRestored",
      ])
  }

  // MARK: - each containment layer on its own

  func testAMissingTargetOutsideTheDataDirectoryIsStillRefused() throws {
    // Only the lexical check can catch this: nothing exists to resolve.
    XCTAssertThrowsError(
      try clearDirectoryContents(dataDirectory: data, target: root + "/does-not-exist"))
    XCTAssertThrowsError(
      try clearDirectoryContents(dataDirectory: data, target: data + "/../does-not-exist"))
  }

  func testATargetReachedThroughAnIntermediateSymlinkIsNeverCleared() throws {
    let outside = root + "/outside/Caches/keep.bin"
    try write(outside)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/link", withDestinationPath: root + "/outside")
    // data/link/Caches is a real directory, lexically inside data, physically outside.
    XCTAssertThrowsError(
      try clearDirectoryContents(dataDirectory: data, target: data + "/link/Caches")
    ) {
      XCTAssertTrue("\($0)".contains("refusing symlinked cleanup path"), "\($0)")
    }
    XCTAssertTrue(exists(outside))
  }

  func testAFixedLogPathThatIsASymlinkIsNotATargetAndIsNeverFollowed() throws {
    let outside = root + "/outside/keep.log"
    try write(outside)
    try FileManager.default.createDirectory(
      atPath: data + "/Library", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/Library/Logs", withDestinationPath: root + "/outside")
    XCTAssertEqual(try diskCleanupTargets(dataDirectory: data, categoryID: "logs"), [])
    let result = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["logs"])
    XCTAssertEqual(result.reclaimedBytes, 0)
    XCTAssertTrue(exists(outside))
    XCTAssertTrue(exists(data + "/Library/Logs"), "the symlink itself is left alone")
  }

  func testWalksNeverDescendIntoASymlinkedDirectory() throws {
    try write(root + "/outside/Caches/huge.bin", size: 200_000)
    try write(data + "/own/small.bin", size: 100)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/own/link", withDestinationPath: root + "/outside")
    // A symlink counts as the small entry it is, not the 200 KB it points at.
    XCTAssertLessThan(try allocatedSize(data + "/own"), 100_000)
    XCTAssertLessThan(try allocatedSizeExcludingNames(data + "/own", excluded: []), 100_000)
    // And name discovery does not walk through it either.
    XCTAssertEqual(try findNamedDirectories(root: data, name: "Caches", excludedAncestors: []), [])
    XCTAssertEqual(try diskCleanupTargets(dataDirectory: data, categoryID: "caches"), [])
  }

  func testTemporaryDirectoriesInsideCachesBelongToCachesAlone() throws {
    try write(data + "/Library/Caches/work/tmp/x.bin")
    try write(data + "/Library/tmp/y.bin")
    XCTAssertEqual(
      try diskCleanupTargets(dataDirectory: data, categoryID: "caches"), [data + "/Library/Caches"])
    XCTAssertEqual(
      try diskCleanupTargets(dataDirectory: data, categoryID: "temporary"), [data + "/Library/tmp"])
    let p = try plan()
    let temp = try XCTUnwrap(p.categories.first { $0.category.id == "temporary" })
    XCTAssertEqual(temp.targets, 1)
  }

  // MARK: - from the independent review

  func testASymlinkInsideTheDataDirectoryCannotRedirectAFixedPathIntoProtectedData() throws {
    let photo = data + "/Media/log/precious-photo.heic"
    try write(photo)
    // data/var -> data/Media: lexically data/var/log, physically data/Media/log.
    try FileManager.default.createSymbolicLink(
      atPath: data + "/var", withDestinationPath: data + "/Media")
    XCTAssertThrowsError(try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["logs"])) {
      XCTAssertTrue("\($0)".contains("refusing symlinked cleanup path"), "\($0)")
    }
    XCTAssertTrue(exists(photo), "user media was deleted through an in-tree symlink")
    XCTAssertThrowsError(
      try clearDirectoryContents(dataDirectory: data, target: data + "/var/log"))
    XCTAssertTrue(exists(photo))
  }

  func testEveryFixedPathIsGuardedAgainstInTreeRedirects() throws {
    let precious = data + "/Containers/Data/Application/A/Documents"
    try write(precious + "/log/keep.bin")
    try write(precious + "/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData/keep.bin")
    for (link, category) in [("Library", "logs"), ("private", "linguistic-data")] {
      try? FileManager.default.removeItem(atPath: data + "/" + link)
      try FileManager.default.createSymbolicLink(
        atPath: data + "/" + link, withDestinationPath: precious)
      if link == "Library" { try write(precious + "/Logs/keep.log") }
      if link == "private" {
        try write(
          precious + "/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData/keep.bin")
      }
      XCTAssertThrowsError(
        try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: [category]), "\(link)")
      try FileManager.default.removeItem(atPath: data + "/" + link)
    }
    XCTAssertTrue(exists(precious + "/log/keep.bin"))
    XCTAssertTrue(exists(precious + "/Logs/keep.log"))
    XCTAssertTrue(
      exists(
        precious + "/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData/keep.bin"))
  }

  func testAppleDoubleFilesAreListedMeasuredAndCleaned() throws {
    try write(data + "/Library/Caches/real.bin", size: 100)
    try write(data + "/Library/Caches/._real.bin", size: 100_000)
    let names = try readDirectory(data + "/Library/Caches").map(\.name)
    XCTAssertEqual(names, ["._real.bin", "real.bin"], "readdir does not hide ._ files")
    XCTAssertGreaterThan(try allocatedSize(data + "/Library/Caches"), 100_000)
    let result = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["caches"])
    XCTAssertFalse(exists(data + "/Library/Caches/._real.bin"))
    XCTAssertFalse(exists(data + "/Library/Caches/real.bin"))
    XCTAssertEqual(result.afterBytes, try allocatedSize(data + "/Library/Caches"))
  }

  func testDirectoryListingIsSortedByBytesAndReportsTypes() throws {
    try write(data + "/b/file")
    try FileManager.default.createDirectory(atPath: data + "/a", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: data + "/c", withDestinationPath: data + "/a")
    let entries = try readDirectory(data)
    XCTAssertEqual(entries.map(\.name), ["a", "b", "c"])
    XCTAssertEqual(entries.map(\.isDirectory), [true, true, false], "a symlink is not a directory")
    XCTAssertThrowsError(try readDirectory(data + "/missing"))
  }

  func testAChildThatIsAlreadyGoneIsNotAnError() throws {
    XCTAssertNoThrow(try removeIfPresent(data + "/never-existed"))
    try write(data + "/x/y.bin")
    XCTAssertNoThrow(try removeIfPresent(data + "/x"))
    XCTAssertFalse(exists(data + "/x"))
    // A real failure is still an error: a directory we may not touch.
    try write(data + "/locked/inner.bin")
    chmod(data + "/locked", 0o500)
    defer { chmod(data + "/locked", 0o700) }
    XCTAssertThrowsError(try removeIfPresent(data + "/locked/inner.bin"))
  }

  func testDiscoveryToleratesADirectoryThatVanishes() throws {
    try write(data + "/a/Caches/x.bin")
    try write(data + "/gone/Caches/y.bin")
    // Simulate the race: the directory listing names `gone`, then it is deleted.
    var removed = false
    var found: [String] = []
    try walkDirectoriesForTest(data) { path in
      if path == data + "/a" || path == data + "/gone", !removed {
        removed = true
        try? FileManager.default.removeItem(atPath: data + "/gone")
      }
      if (path as NSString).lastPathComponent == "Caches" { found.append(path) }
      return true
    }
    XCTAssertTrue(found.contains(data + "/a/Caches"))
  }

  func testPathsWithCombiningMarksAreJudgedByBytes() throws {
    XCTAssertTrue(isStrictDescendant("/d", "/d/\u{301}x"))
    XCTAssertTrue(isStrictDescendant("/d", "/d/\u{301}x/Caches"))
    XCTAssertEqual(cleanPath("/d/\u{301}x/../y"), "/d/y")
    XCTAssertFalse(isStrictDescendant("/d", "/d\u{301}"), "a different name, not a child")
    try write(data + "/\u{301}odd/Library/Caches/c.bin")
    XCTAssertNoThrow(try plan())
    _ = try cleanDisk(udid: "T", dataDirectory: data, categoryIDs: ["caches"])
    XCTAssertFalse(exists(data + "/\u{301}odd/Library/Caches/c.bin"))
  }

  func testQuotedCategoryNamesUseGosRules() {
    XCTAssertThrowsError(try validateDiskCleanupSelection(["bad\u{200D}id"])) {
      XCTAssertEqual("\($0)", "unknown disk cleanup category \"bad\\u200did\"")
    }
  }
}
