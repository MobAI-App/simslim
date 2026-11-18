import Foundation

/// One device's directory, named by its UDID, in a scanned device set.
struct DeviceDir: Equatable, Sendable {
  var path: String
  var set: String
}

/// Calls `created` for each directory that appears in one of `setDirs`, until
/// `stop` returns true. A kqueue NOTE_WRITE on each set directory wakes it within
/// a millisecond of `simctl create`, and costs nothing while idle. A set
/// directory that does not exist yet (XCTestDevices before the first
/// parallel-testing run) is attached again on every pass; its devices count as
/// new from then on. A deleted device directory is forgotten, so `known` holds
/// only the devices that exist.
///
/// `setDirs` maps a set directory to the set's name. The first listing of each
/// directory is the baseline, taken at startup: those devices are the first
/// scan's business, not reported here.
func watchDeviceDirs(
  setDirs: [String: String], pollInterval: TimeInterval = 0.25,
  stop: @Sendable () -> Bool, created: (DeviceDir) -> Void
) {
  let kq = kqueue()
  if kq < 0 { return }  // the scan still catches every device, only later
  defer { close(kq) }

  var fds: [String: Int32] = [:]  // attached set directory -> its fd
  var dirs: [UInt: String] = [:]  // fd -> attached set directory
  var known: [String: Set<String>] = [:]  // set directory -> its device directories
  defer { for fd in fds.values { close(fd) } }

  func list(_ dir: String, report: Bool) {
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
    let was = known[dir] ?? []
    var now = Set<String>()
    for name in entries.sorted() {
      var isDirectory: ObjCBool = false
      let path = (dir as NSString).appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
        isDirectory.boolValue
      else { continue }
      now.insert(name)
      if report && !was.contains(name) {
        created(DeviceDir(path: path, set: setDirs[dir] ?? ""))
      }
    }
    known[dir] = now
  }

  func attach(report: Bool) {
    for dir in setDirs.keys.sorted() where fds[dir] == nil {
      let fd = open(dir, O_EVTONLY | O_DIRECTORY)
      if fd < 0 { continue }
      var change = kevent(
        ident: UInt(fd), filter: Int16(EVFILT_VNODE), flags: UInt16(EV_ADD | EV_CLEAR),
        fflags: UInt32(NOTE_WRITE | NOTE_DELETE | NOTE_RENAME), data: 0, udata: nil)
      if kevent(kq, &change, 1, nil, 0, nil) < 0 {
        close(fd)
        continue
      }
      fds[dir] = fd
      dirs[UInt(fd)] = dir
      list(dir, report: report)
    }
  }

  attach(report: false)
  var events: [kevent] = Array(repeating: kevent(), count: max(setDirs.count, 1))
  var timeout = timespec(
    tv_sec: Int(pollInterval), tv_nsec: Int((pollInterval - floor(pollInterval)) * 1e9))
  while !stop() {
    let n = kevent(kq, nil, 0, &events, Int32(events.count), &timeout)
    if n < 0 && errno != EINTR { return }
    for event in events[0..<max(Int(n), 0)] {
      guard let dir = dirs[event.ident], event.filter == Int16(EVFILT_VNODE) else { continue }
      if event.fflags & UInt32(NOTE_DELETE | NOTE_RENAME) != 0 {
        // The set directory itself went away; attach it again once it is back,
        // and report what it holds then.
        if let fd = fds[dir] { close(fd) }
        fds[dir] = nil
        dirs[event.ident] = nil
        known[dir] = nil
        continue
      }
      list(dir, report: true)
    }
    attach(report: true)
  }
}
