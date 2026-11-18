import Foundation
import XCTest

@testable import SimSlimKit

final class CloneFilesystemTests: XCTestCase {
  private let src = "AAAAAAAA-0000-0000-0000-000000000001"
  private let dst = "BBBBBBBB-0000-0000-0000-000000000002"
  private var root = ""
  private let fm = FileManager.default

  override func setUpWithError() throws {
    root = try resolvedPath(NSTemporaryDirectory()) + "/simslim-clonefs-\(UUID().uuidString)"
    try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
    for udid in [src, dst] {
      try fm.createDirectory(
        atPath: "\(root)/devices/\(udid)/data", withIntermediateDirectories: true)
      try fm.createDirectory(
        atPath: "\(root)/home/Library/Logs/CoreSimulator/\(udid)", withIntermediateDirectories: true
      )
    }
  }

  override func tearDown() { try? fm.removeItem(atPath: root) }

  private var paths: CloneFilesystem {
    CloneFilesystem(
      sourceUDID: src, cloneUDID: dst,
      sourceDeviceDirectory: "\(root)/devices/\(src)",
      cloneDeviceDirectory: "\(root)/devices/\(dst)",
      sourceDataDirectory: "\(root)/devices/\(src)/data",
      cloneDataDirectory: "\(root)/devices/\(dst)/data",
      sourceLogDirectory: "\(root)/home/Library/Logs/CoreSimulator/\(src)",
      cloneLogDirectory: "\(root)/home/Library/Logs/CoreSimulator/\(dst)")
  }

  private var cloneData: String { paths.cloneDataDirectory }
  private var sourceData: String { paths.sourceDataDirectory }

  private func write(_ path: String, _ text: String = "x") throws {
    try fm.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: URL(fileURLWithPath: path))
  }

  private func exists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
  }

  private func message(_ body: () throws -> Void) -> String {
    do {
      try body()
      return ""
    } catch { return "\(error)" }
  }

  // MARK: - path logic

  func testRebasePathMapsOnlyWhatIsAtOrBelowTheSource() {
    XCTAssertEqual(rebasePath("/s/dev", sourceRoot: "/s/dev", cloneRoot: "/s/new"), "/s/new")
    XCTAssertEqual(
      rebasePath("/s/dev/a/b", sourceRoot: "/s/dev", cloneRoot: "/s/new"), "/s/new/a/b")
    XCTAssertEqual(
      rebasePath("/s/dev/a/../b", sourceRoot: "/s/dev/", cloneRoot: "/s/new"), "/s/new/b")
    XCTAssertNil(
      rebasePath("/s/device", sourceRoot: "/s/dev", cloneRoot: "/s/new"),
      "a name prefix is not a parent")
    XCTAssertNil(rebasePath("/s/dev/../x", sourceRoot: "/s/dev", cloneRoot: "/s/new"))
    XCTAssertNil(rebasePath("/other", sourceRoot: "/s/dev", cloneRoot: "/s/new"))
    XCTAssertNil(
      rebasePath("a/b", sourceRoot: "/s/dev", cloneRoot: "/s/new"), "relative is never mapped")
    XCTAssertEqual(rebasePath("/x/y", sourceRoot: "/", cloneRoot: "/z"), "/z/x/y")
  }

  func testRelativePath() {
    XCTAssertEqual(relativePath(from: "/a/b", to: "/a/b/c/d"), "c/d")
    XCTAssertEqual(relativePath(from: "/a/b/c", to: "/a/x"), "../../x")
    XCTAssertEqual(relativePath(from: "/a/b", to: "/a/b"), ".")
    XCTAssertEqual(relativePath(from: "/a/b", to: "/a"), "..")
    XCTAssertEqual(relativePath(from: "/", to: "/a"), "a")
  }

  func testPathContainsComponent() {
    XCTAssertTrue(pathContainsComponent("/x/UDID/y", "UDID"))
    XCTAssertTrue(pathContainsComponent("rel/UDID", "UDID"))
    XCTAssertFalse(pathContainsComponent("/x/UDIDS/y", "UDID"))
    XCTAssertFalse(pathContainsComponent("/x/UDID/../y", "UDID"), "cleaned first")
    XCTAssertFalse(pathContainsComponent("/x/y", ""))
  }

  func testClonedUDIDParsing() throws {
    XCTAssertEqual(try Simctl.parseClonedUDID("  \(src)\n"), src)
    XCTAssertEqual(try Simctl.parseClonedUDID(src.lowercased()), src.lowercased())
    for bad in [
      "", "garbage", src + "0", String(src.dropLast()),
      src.replacingOccurrences(of: "-", with: "_"),
      "ZZZZZZZZ-0000-0000-0000-000000000001", "warning\n" + src,
    ] {
      XCTAssertThrowsError(try Simctl.parseClonedUDID(bad), bad) {
        XCTAssertTrue("\($0)".hasPrefix("simctl clone returned an invalid UDID"), "\($0)")
      }
    }
  }

  func testOnlySlimmableOverridesAreCarriedOver() {
    let slimmable = Catalog.categories[0].labels[0]
    let alwaysOn = Catalog.categories.flatMap(\.alwaysEnabled)[0].label
    let carried = desiredCloneDisabled([slimmable, alwaysOn, "com.example.unrelated"])
    XCTAssertEqual(carried, [slimmable])
  }

  // MARK: - the running audit

  func testProcessIDsComeFromTheEnvironmentMarker() {
    let ps = """
        10 /bin/a FOO=1 SIMULATOR_UDID=\(dst) BAR=2
        11 /bin/b SIMULATOR_UDID=\(src)
      200 /bin/c SIMULATOR_UDID=\(dst)
       10 /bin/dup SIMULATOR_UDID=\(dst)
      bad /bin/e SIMULATOR_UDID=\(dst)
       -5 /bin/f SIMULATOR_UDID=\(dst)
       12 /bin/g
      """
    XCTAssertEqual(Simctl.simulatorProcessIDs(fromPS: ps, udid: dst), [10, 200])
  }

  func testLsofParsingFindsSourcePathsInTheDeviceAndItsLogs() {
    let output = """
      p10
      n/dev/null
      n\(paths.sourceDeviceDirectory)/data/Library/x
      p20
      n\(paths.sourceLogDirectory)/launchd.log
      n\(paths.cloneDeviceDirectory)/data/ok
      pjunk
      n\(paths.sourceDeviceDirectory)/ignored-without-a-pid
      """
    let parsed = Simctl.parseCloneLsofOutput(output, paths: paths)
    XCTAssertTrue(parsed.hasRecords)
    XCTAssertEqual(
      parsed.references.map { "\($0.pid) \($0.path)" },
      [
        "10 \(paths.sourceDeviceDirectory)/data/Library/x",
        "20 \(paths.sourceLogDirectory)/launchd.log",
      ])
    XCTAssertFalse(Simctl.parseCloneLsofOutput("garbage\nx\n", paths: paths).hasRecords)
    XCTAssertFalse(Simctl.parseCloneLsofOutput("n/foo\n", paths: paths).hasRecords, "no pid yet")
  }

  func testAuditOutcomes() {
    let clean = "p10\nn/dev/null\n"
    XCTAssertTrue(Simctl.evaluateCloneLsofAudit(clean, commandFailure: nil, paths: paths).complete)
    XCTAssertNil(Simctl.evaluateCloneLsofAudit(clean, commandFailure: nil, paths: paths).error)
    // lsof exits 1 when a pid exited, but live processes still produced records.
    let churn = Simctl.evaluateCloneLsofAudit(clean, commandFailure: "exit status 1", paths: paths)
    XCTAssertTrue(churn.complete)
    XCTAssertNil(churn.error)
    let leak = Simctl.evaluateCloneLsofAudit(
      "p10\nn\(paths.sourceDeviceDirectory)/data/f\n", commandFailure: "exit status 1", paths: paths
    )
    XCTAssertTrue(leak.complete)
    XCTAssertEqual(
      leak.error,
      "clone process 10 still has a source simulator path open: \(paths.sourceDeviceDirectory)/data/f"
    )
    let empty = Simctl.evaluateCloneLsofAudit("", commandFailure: "exit status 1", paths: paths)
    XCTAssertFalse(empty.complete)
    XCTAssertEqual(empty.error, "audit cloned simulator open files: exit status 1")
    let said = Simctl.evaluateCloneLsofAudit(
      " boom \n", commandFailure: "exit status 1", paths: paths)
    XCTAssertEqual(said.error, "audit cloned simulator open files: exit status 1: boom")
    let silent = Simctl.evaluateCloneLsofAudit("", commandFailure: nil, paths: paths)
    XCTAssertFalse(silent.complete)
    XCTAssertEqual(
      silent.error, "audit cloned simulator open files returned no process or path records")
  }

  // MARK: - validation

  func testValidationRejectsBadDirectoriesAndEqualUDIDs() throws {
    XCTAssertEqual(message { try validateCloneFilesystem(self.paths) }, "")
    var same = paths
    same.cloneUDID = src
    XCTAssertTrue(message { try validateCloneFilesystem(same) }.contains("must be distinct"))
    var empty = paths
    empty.sourceUDID = ""
    XCTAssertTrue(message { try validateCloneFilesystem(empty) }.contains("must be distinct"))
    var missing = paths
    missing.cloneDeviceDirectory += "-gone"
    XCTAssertTrue(
      message { try validateCloneFilesystem(missing) }.contains("locate clone device directory"))

    // A data directory that is a symlink is not a real directory.
    try fm.removeItem(atPath: cloneData)
    try fm.createSymbolicLink(atPath: cloneData, withDestinationPath: sourceData)
    XCTAssertTrue(
      message { try validateCloneFilesystem(self.paths) }.contains(
        "clone data path is not a real directory"))
  }

  func testValidationRejectsADataDirectoryOutsideItsDevice() throws {
    var wrong = paths
    wrong.cloneDataDirectory = sourceData
    XCTAssertTrue(message { try validateCloneFilesystem(wrong) }.contains("refusing"))
  }

  // MARK: - generated stores

  func testLaunchServicesStoresAreRemovedAndNothingElse() throws {
    let lsd = cloneData + "/var/db/lsd"
    try write(lsd + "/com.apple.LaunchServices-6040.csstore")
    try write(lsd + "/com.apple.LaunchServices-ConfigV2.csstore.sb")
    try write(lsd + "/com.apple.LaunchServices-keep.txt")
    try write(lsd + "/other.csstore")
    try resetClonedLaunchServices(dataDirectory: cloneData)
    XCTAssertFalse(exists(lsd + "/com.apple.LaunchServices-6040.csstore"))
    XCTAssertFalse(exists(lsd + "/com.apple.LaunchServices-ConfigV2.csstore.sb"))
    XCTAssertTrue(exists(lsd + "/com.apple.LaunchServices-keep.txt"), "needs .csstore in the name")
    XCTAssertTrue(exists(lsd + "/other.csstore"), "needs the LaunchServices- prefix")
  }

  func testAMissingLaunchServicesDirectoryIsFine() throws {
    XCTAssertEqual(message { try resetClonedLaunchServices(dataDirectory: self.cloneData) }, "")
    XCTAssertEqual(message { try resetClonedFrontBoard(dataDirectory: self.cloneData) }, "")
  }

  func testLaunchServicesRefusesAnythingButRealFilesAndDirectories() throws {
    let lsd = cloneData + "/var/db/lsd"
    try fm.createDirectory(
      atPath: lsd + "/com.apple.LaunchServices-1.csstore", withIntermediateDirectories: true)
    XCTAssertTrue(
      message { try resetClonedLaunchServices(dataDirectory: self.cloneData) }
        .contains("cloned LaunchServices store is not a regular file"))
    XCTAssertTrue(exists(lsd + "/com.apple.LaunchServices-1.csstore"))

    try fm.removeItem(atPath: lsd + "/com.apple.LaunchServices-1.csstore")
    try write(sourceData + "/victim.csstore")
    try fm.createSymbolicLink(
      atPath: lsd + "/com.apple.LaunchServices-2.csstore",
      withDestinationPath: sourceData + "/victim.csstore")
    XCTAssertTrue(
      message { try resetClonedLaunchServices(dataDirectory: self.cloneData) }
        .contains("not a regular file"))
    XCTAssertTrue(exists(sourceData + "/victim.csstore"), "a link is never followed")

    try fm.removeItem(atPath: cloneData + "/var/db/lsd")
    try fm.createSymbolicLink(atPath: cloneData + "/var/db/lsd", withDestinationPath: sourceData)
    XCTAssertTrue(
      message { try resetClonedLaunchServices(dataDirectory: self.cloneData) }
        .contains("cloned LaunchServices path is not a real directory"))
  }

  func testFrontBoardRemovesOnlyItsThreeDatabaseFiles() throws {
    let dir = cloneData + "/Library/FrontBoard"
    for name in [
      "applicationState.db", "applicationState.db-shm", "applicationState.db-wal", "keep.db",
    ] {
      try write(dir + "/" + name)
    }
    try resetClonedFrontBoard(dataDirectory: cloneData)
    XCTAssertFalse(exists(dir + "/applicationState.db"))
    XCTAssertFalse(exists(dir + "/applicationState.db-shm"))
    XCTAssertFalse(exists(dir + "/applicationState.db-wal"))
    XCTAssertTrue(exists(dir + "/keep.db"))
    try fm.removeItem(atPath: dir + "/keep.db")
    try fm.createDirectory(atPath: dir + "/applicationState.db", withIntermediateDirectories: true)
    XCTAssertTrue(
      message { try resetClonedFrontBoard(dataDirectory: self.cloneData) }
        .contains("cloned FrontBoard store is not a regular file"))
  }

  func testGeneratedPathStateIsClearedButItsDirectoriesAndNeighboursStay() throws {
    let cleared = [
      "Library/AppleMediaServices/Engagement/internal/database", "Library/Spotlight",
      "Library/chronod/replicator", "Library/com.apple.nsurlsessiond",
      "private/var/MobileAsset/AssetsV2/locks", "private/var/MobileAsset/AssetsV2/persisted",
      "private/var/db/assetsubscriptiond/history", "var/db/diagnostics/Persist",
      "var/db/diagnostics/Special", "Containers/Shared/AppGroup/G1/replicatord",
      "Containers/Shared/AppGroup/.hidden/replicatord",
    ]
    for dir in cleared {
      try write("\(cloneData)/\(dir)/a.db")
      try write("\(cloneData)/\(dir)/sub/b.db")
    }
    let kept = [
      "private/var/MobileAsset/AssetsV2/downloads/payload", "Library/Spotlight-other/x",
      "var/db/diagnostics/Other/x", "Containers/Shared/AppGroup/G1/keep", "Documents/doc",
      "Containers/Data/Application/APP/Documents/d",
    ]
    for file in kept { try write("\(cloneData)/\(file)") }
    try write(cloneData + "/Containers/Shared/AppGroup/not-a-group-dir")

    try resetClonedGeneratedPathState(dataDirectory: cloneData)
    for dir in cleared {
      var isDir: ObjCBool = false
      XCTAssertTrue(fm.fileExists(atPath: "\(cloneData)/\(dir)", isDirectory: &isDir), dir)
      XCTAssertTrue(isDir.boolValue)
      XCTAssertEqual(try fm.contentsOfDirectory(atPath: "\(cloneData)/\(dir)"), [], dir)
    }
    for file in kept { XCTAssertTrue(exists("\(cloneData)/\(file)"), file) }
  }

  func testAnInTreeSymlinkCannotRedirectGeneratedStateCleanupIntoUserData() throws {
    try write(cloneData + "/Media/photos/p.jpg")
    try fm.createDirectory(atPath: cloneData + "/private/var/db", withIntermediateDirectories: true)
    // `var` is a link: var/db/diagnostics/Persist would land in Media.
    try fm.createDirectory(
      atPath: cloneData + "/Media/db/diagnostics/Persist", withIntermediateDirectories: true)
    try write(cloneData + "/Media/db/diagnostics/Persist/precious")
    try fm.createSymbolicLink(atPath: cloneData + "/var", withDestinationPath: cloneData + "/Media")
    let text = message { try resetClonedGeneratedPathState(dataDirectory: self.cloneData) }
    XCTAssertTrue(text.contains("refusing symlinked cleanup path"), text)
    XCTAssertTrue(exists(cloneData + "/Media/db/diagnostics/Persist/precious"))
    XCTAssertTrue(exists(cloneData + "/Media/photos/p.jpg"))
  }

  func testASymlinkedAppGroupIsRefusedNotFollowed() throws {
    try write(cloneData + "/Documents/replicatord/precious")
    try fm.createDirectory(
      atPath: cloneData + "/Containers/Shared/AppGroup", withIntermediateDirectories: true)
    try fm.createSymbolicLink(
      atPath: cloneData + "/Containers/Shared/AppGroup/G",
      withDestinationPath: cloneData + "/Documents")
    let text = message { try resetClonedGeneratedPathState(dataDirectory: self.cloneData) }
    XCTAssertTrue(text.contains("refusing symlinked cleanup path"), text)
    XCTAssertTrue(exists(cloneData + "/Documents/replicatord/precious"))
  }

  func testTransientStateIsClearedBySanitize() throws {
    try write(cloneData + "/Library/Caches/c/cache.bin")
    try write(cloneData + "/tmp/t.tmp")
    try write(cloneData + "/Library/Preferences/keep.txt")
    try sanitizeClonedDevice(paths)
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: cloneData + "/Library/Caches"), [])
    XCTAssertEqual(try fm.contentsOfDirectory(atPath: cloneData + "/tmp"), [])
    XCTAssertTrue(exists(cloneData + "/Library/Preferences/keep.txt"))
  }

  // MARK: - rebasing

  func testPropertyListsPointAtTheCloneAndKeepTheirMode() throws {
    let xml = "<plist><string>file://\(sourceData)/Media/wall.jpg</string></plist>"
    let target = cloneData + "/Library/Preferences/a.plist"
    try write(target, xml)
    XCTAssertEqual(chmod(target, 0o600), 0)
    let upper = cloneData + "/Library/Preferences/B.PLIST"
    try write(upper, "ref \(src) and again \(src)")
    let untouched = cloneData + "/Library/Preferences/c.plist"
    try write(untouched, "nothing here")
    let other = cloneData + "/Library/Preferences/notes.txt"
    try write(other, "ref \(src)")
    var before = stat()
    XCTAssertEqual(stat(untouched, &before), 0)

    try rebaseClonePropertyLists(paths)

    XCTAssertEqual(
      try String(contentsOfFile: target, encoding: .utf8),
      xml.replacingOccurrences(of: src, with: dst))
    XCTAssertEqual(
      try String(contentsOfFile: upper, encoding: .utf8), "ref \(dst) and again \(dst)")
    XCTAssertEqual(
      try String(contentsOfFile: other, encoding: .utf8), "ref \(src)", "only .plist files")
    var after = stat()
    XCTAssertEqual(stat(untouched, &after), 0)
    XCTAssertEqual(before.st_ino, after.st_ino, "a file with nothing to change is not rewritten")
    var info = stat()
    XCTAssertEqual(stat(target, &info), 0)
    XCTAssertEqual(info.st_mode & 0o777, 0o600)
    XCTAssertEqual(
      try fm.contentsOfDirectory(atPath: cloneData + "/Library/Preferences").filter {
        $0.hasPrefix(".simslim")
      }, [],
      "no temporary file is left behind")
  }

  func testBinaryPropertyListBytesAreReplacedInPlace() throws {
    let path = cloneData + "/a.plist"
    var bytes = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x00, 0xFF])
    bytes.append(Data(src.utf8))
    bytes.append(0x00)
    try bytes.write(to: URL(fileURLWithPath: path))
    try rebaseClonePropertyLists(paths)
    var expected = Data([0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x00, 0xFF])
    expected.append(Data(dst.utf8))
    expected.append(0x00)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), expected)
  }

  func testPropertyListRebaseNeedsEqualLengthUDIDs() {
    var short = paths
    short.cloneUDID = "SHORT"
    XCTAssertEqual(
      message { try rebaseClonePropertyLists(short) },
      "source and clone UDIDs must have equal lengths")
  }

  func testPropertyListsOutsideTheCloneAreNeverTouched() throws {
    let sourcePlist = sourceData + "/a.plist"
    try write(sourcePlist, "ref \(src)")
    try rebaseClonePropertyLists(paths)
    XCTAssertEqual(try String(contentsOfFile: sourcePlist, encoding: .utf8), "ref \(src)")
  }

  func testSymlinksIntoTheSourceAreRebasedAbsoluteAndRelative() throws {
    try write(sourceData + "/Media/file")
    let lib = cloneData + "/Library"
    try fm.createDirectory(atPath: lib, withIntermediateDirectories: true)
    try fm.createSymbolicLink(atPath: lib + "/abs", withDestinationPath: sourceData + "/Media/file")
    try fm.createSymbolicLink(
      atPath: lib + "/rel", withDestinationPath: "../../../\(src)/data/Media/file")
    try fm.createSymbolicLink(atPath: lib + "/logs", withDestinationPath: paths.sourceLogDirectory)
    try fm.createSymbolicLink(
      atPath: lib + "/logfile", withDestinationPath: paths.sourceLogDirectory + "/launchd.log")
    try fm.createSymbolicLink(atPath: lib + "/self", withDestinationPath: cloneData + "/Media")
    try fm.createSymbolicLink(atPath: lib + "/elsewhere", withDestinationPath: "/usr/lib")
    try fm.createSymbolicLink(atPath: lib + "/sibling", withDestinationPath: "../Media")

    try rebaseCloneSymlinks(paths)

    func dest(_ name: String) throws -> String {
      try fm.destinationOfSymbolicLink(atPath: lib + "/" + name)
    }
    XCTAssertEqual(try dest("abs"), cloneData + "/Media/file")
    XCTAssertEqual(try dest("rel"), "../Media/file", "a relative link stays relative")
    XCTAssertEqual(try dest("logs"), paths.cloneLogDirectory)
    XCTAssertEqual(try dest("logfile"), paths.cloneLogDirectory + "/launchd.log")
    XCTAssertEqual(try dest("self"), cloneData + "/Media")
    XCTAssertEqual(try dest("elsewhere"), "/usr/lib")
    XCTAssertEqual(try dest("sibling"), "../Media")
    XCTAssertEqual(
      try fm.contentsOfDirectory(atPath: lib).filter { $0.hasPrefix(".simslim") }, [])
  }

  func testRebasingNeverFollowsOrTouchesTheSource() throws {
    try fm.createSymbolicLink(atPath: sourceData + "/link", withDestinationPath: sourceData + "/x")
    // A clone link to a directory in the source must be replaced, not entered.
    try write(sourceData + "/dir/inner")
    try fm.createSymbolicLink(
      atPath: cloneData + "/dirlink", withDestinationPath: sourceData + "/dir")
    try rebaseCloneSymlinks(paths)
    XCTAssertEqual(
      try fm.destinationOfSymbolicLink(atPath: cloneData + "/dirlink"), cloneData + "/dir")
    XCTAssertEqual(
      try fm.destinationOfSymbolicLink(atPath: sourceData + "/link"), sourceData + "/x")
    XCTAssertTrue(exists(sourceData + "/dir/inner"))
  }

  // MARK: - independence

  func testIndependenceFlagsLinksIntoTheSourceAndNamingItsUDID() throws {
    try fm.createSymbolicLink(atPath: cloneData + "/a", withDestinationPath: sourceData + "/x")
    XCTAssertTrue(
      message { try verifyCloneIndependence(self.paths) }.contains(
        "still resolves into the source simulator"))
    try fm.removeItem(atPath: cloneData + "/a")

    try fm.createSymbolicLink(atPath: cloneData + "/b", withDestinationPath: "/elsewhere/\(src)/y")
    XCTAssertTrue(
      message { try verifyCloneIndependence(self.paths) }.contains(
        "still resolves into the source simulator"))
    try fm.removeItem(atPath: cloneData + "/b")

    // A dangling relative link whose text names the source is caught too.
    try fm.createSymbolicLink(atPath: cloneData + "/c", withDestinationPath: "../\(src)/z")
    XCTAssertTrue(
      message { try verifyCloneIndependence(self.paths) }.contains(
        "still resolves into the source simulator"))
    try fm.removeItem(atPath: cloneData + "/c")

    try fm.createSymbolicLink(atPath: cloneData + "/ok", withDestinationPath: cloneData + "/Media")
    XCTAssertEqual(message { try verifyCloneIndependence(self.paths) }, "")
  }

  func testIndependenceFlagsAHardLinkToTheSource() throws {
    try write(sourceData + "/Media/shared.bin")
    try write(cloneData + "/Media/copy.bin")
    try write(sourceData + "/Media/copy.bin", "different file, same name")
    XCTAssertEqual(
      message { try verifyCloneIndependence(self.paths) }, "", "same name, different file")

    try fm.removeItem(atPath: cloneData + "/Media/copy.bin")
    XCTAssertEqual(link(sourceData + "/Media/copy.bin", cloneData + "/Media/copy.bin"), 0)
    let text = message { try verifyCloneIndependence(self.paths) }
    XCTAssertTrue(text.contains("is hard-linked to the source simulator"), text)
  }

  func testIndependenceIgnoresFilesWithNoSourceCounterpart() throws {
    try write(cloneData + "/only-in-clone")
    XCTAssertEqual(message { try verifyCloneIndependence(self.paths) }, "")
  }

  func testSanitizeEndToEndLeavesACloneThatPassesTheCheck() throws {
    try write(sourceData + "/Media/photo.jpg", "photo")
    try write(cloneData + "/Media/photo.jpg", "photo")
    try write(cloneData + "/var/db/lsd/com.apple.LaunchServices-1.csstore")
    try write(
      cloneData + "/Library/Preferences/p.plist", "<string>\(sourceData)/Media/photo.jpg</string>")
    try fm.createSymbolicLink(
      atPath: cloneData + "/Library/Logs", withDestinationPath: paths.sourceLogDirectory)
    try sanitizeClonedDevice(paths)
    XCTAssertFalse(exists(cloneData + "/var/db/lsd/com.apple.LaunchServices-1.csstore"))
    XCTAssertEqual(
      try fm.destinationOfSymbolicLink(atPath: cloneData + "/Library/Logs"), paths.cloneLogDirectory
    )
    XCTAssertEqual(
      try String(contentsOfFile: cloneData + "/Library/Preferences/p.plist", encoding: .utf8),
      "<string>\(cloneData)/Media/photo.jpg</string>")
    XCTAssertEqual(
      try String(contentsOfFile: cloneData + "/Media/photo.jpg", encoding: .utf8), "photo")
  }

  func testSanitizeFailsRatherThanLeavingAnUnsafeClone() throws {
    // A link the rebase cannot express still names the source: the final check fails.
    try fm.createSymbolicLink(atPath: cloneData + "/x", withDestinationPath: "/elsewhere/\(src)/f")
    XCTAssertTrue(
      message { try sanitizeClonedDevice(self.paths) }.contains("still resolves into the source"))
  }

  // MARK: - review follow-ups

  func testLsofPathsNamingTheSourceUDIDAreFlaggedEvenUnderADifferentRoot() {
    // CoreSimulator moved to another volume: lsof prints the real path.
    let output = "p10\nn/Volumes/External/CoreSimulator/Devices/\(src)/data/f\n"
    let parsed = Simctl.parseCloneLsofOutput(output, paths: paths)
    XCTAssertEqual(parsed.references.map(\.pid), [10])
    let clean = Simctl.parseCloneLsofOutput(
      "p10\nn/Volumes/External/CoreSimulator/Devices/\(dst)/data/f\n", paths: paths)
    XCTAssertTrue(clean.references.isEmpty)
  }

  func testValidationRequiresThePathsToLookLikeSetUDIDData() throws {
    var wrongName = paths
    wrongName.cloneDeviceDirectory = "\(root)/devices"
    wrongName.cloneDataDirectory = "\(root)/devices/\(dst)/data"
    XCTAssertNotEqual(message { try validateCloneFilesystem(wrongName) }, "")

    try fm.createDirectory(
      atPath: "\(root)/devices/\(dst)/notdata", withIntermediateDirectories: true)
    var wrongData = paths
    wrongData.cloneDataDirectory = "\(root)/devices/\(dst)/notdata"
    XCTAssertTrue(
      message { try validateCloneFilesystem(wrongData) }.contains("is not <device set>/\(dst)/data")
    )

    var lower = paths
    lower.sourceUDID = src.lowercased()
    XCTAssertEqual(
      message { try validateCloneFilesystem(lower) }, "", "UDID case is not significant")

    var same = paths
    same.cloneUDID = src.lowercased()
    same.cloneDeviceDirectory = paths.sourceDeviceDirectory
    same.cloneDataDirectory = paths.sourceDataDirectory
    XCTAssertTrue(message { try validateCloneFilesystem(same) }.contains("must be distinct"))
  }

  func testAFileThatVanishesMidWalkIsSkippedWhenAsked() throws {
    for name in ["a", "b", "c"] { try write("\(cloneData)/\(name)") }
    var visited: [String] = []
    try walkTree(cloneData, skippingVanished: true) { path, _ in
      visited.append((path as NSString).lastPathComponent)
      if path.hasSuffix("/a") { try? FileManager.default.removeItem(atPath: self.cloneData + "/b") }
      return .descend
    }
    XCTAssertEqual(visited, ["data", "a", "c"])
    try write(cloneData + "/b")
    XCTAssertThrowsError(
      try walkTree(cloneData) { path, _ in
        if path.hasSuffix("/a") {
          try? FileManager.default.removeItem(atPath: self.cloneData + "/b")
        }
        return .descend
      }, "the default stays strict")
  }

  func testAFileInTheSourceAndADirectoryInTheCloneIsNotAnError() throws {
    try write(sourceData + "/x", "file")
    try write(cloneData + "/x/inside", "dir")
    XCTAssertEqual(message { try verifyCloneIndependence(self.paths) }, "")
  }

  func testAnAppGroupDirectoryThatIsAFileIsRefused() throws {
    try write(cloneData + "/Containers/Shared/AppGroup", "not a directory")
    XCTAssertTrue(
      message { try resetClonedGeneratedPathState(dataDirectory: self.cloneData) }
        .contains("is not a real directory"))
    try fm.removeItem(atPath: cloneData + "/Containers/Shared/AppGroup")
    XCTAssertEqual(
      message { try resetClonedGeneratedPathState(dataDirectory: self.cloneData) }, "",
      "absent is fine")
  }
}
