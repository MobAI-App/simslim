// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit

// The state and rendering of `simslim top`, free of any terminal I/O so it can be
// tested: a keypress or a finished measurement goes in, the effects to run and the
// screen text come out.

let topRefresh: TimeInterval = 2  // fleet/process memory refresh cadence
let topDiskTTL: TimeInterval = 30  // disk usage is slow, so refresh it rarely

enum TopKey: Equatable {
  case up, down, left, right, enter, escape, ctrlC
  case character(Character)
}

/// The column both the fleet table and the drill-down sort on.
enum TopSort {
  case ram, cpu, proc, disk, name, state, os
}

/// Header order: name, os, state, proc, cpu, ram, disk. Vim-nav keys (h/j/k/l)
/// are excluded.
let topSortKeys: [Character: TopSort] = [
  "n": .name, "o": .os, "s": .state, "p": .proc, "c": .cpu, "m": .ram, "d": .disk,
]

/// Work the model asks the runner to do; each posts a `TopMessage` when done.
enum TopEffect: Equatable {
  case refreshFleet
  case refreshDisk([String])
  case refreshProcs(String)
  case quit
}

enum TopMessage {
  case resize(width: Int, height: Int)
  case fleet(Result<TopOutput, SimSlimError>)
  case disk([String: Int64])
  case procs(udid: String, Result<[ProcessUsage], SimSlimError>)
}

struct TopModel {
  enum Screen { case fleet, drill }

  var screen = Screen.fleet
  var width = 0
  var height = 0

  var sims: [TopSim] = []
  var total: Int64 = 0
  var cursor = 0
  var cursorUDID = ""  // the selected sim; keeps the cursor anchored across live re-sorts
  var error: String?
  var loaded = false  // the first fleet snapshot has arrived

  var disk: [String: Int64] = [:]
  var diskAt: Date?
  var diskBusy = false  // a du sweep is in flight; don't start another
  var sortCol = TopSort.ram
  var sortDesc = true

  var selUDID = ""
  var selName = ""
  var procs: [ProcessUsage] = []
  var procError: String?
  var scroll = 0

  /// Opens straight into one simulator's per-daemon drill-down when given a UDID.
  init(drillInto udid: String = "", name: String = "") {
    if !udid.isEmpty {
      screen = .drill
      selUDID = udid
      selName = name
    }
  }

  // MARK: - Update

  mutating func start() -> [TopEffect] {
    var effects: [TopEffect] = [.refreshFleet]
    if let procs = refreshProcs() { effects.append(procs) }
    return effects
  }

  private func refreshProcs() -> TopEffect? {
    screen == .drill && !selUDID.isEmpty ? .refreshProcs(selUDID) : nil
  }

  /// The refresh timer fired.
  mutating func tick(now: Date) -> [TopEffect] {
    var effects: [TopEffect] = [.refreshFleet]
    if let procs = refreshProcs() { effects.append(procs) }
    if !diskBusy, let at = diskAt, now.timeIntervalSince(at) > topDiskTTL {
      diskBusy = true
      effects.append(.refreshDisk(sims.map { $0.device.udid }))
    }
    return effects
  }

  mutating func apply(_ message: TopMessage, now: Date) -> [TopEffect] {
    switch message {
    case .resize(let w, let h):
      width = w
      height = h

    case .fleet(.failure(let failure)):
      error = failure.message  // keep showing the previous snapshot; the footer reports it

    case .fleet(.success(let output)):
      error = nil
      loaded = true
      sims = output.sims
      total = output.totalBytes
      applySort()
      reanchor()
      let missing = sims.map { $0.device.udid }.filter { disk[$0] == nil }
      if !missing.isEmpty && !diskBusy {
        diskBusy = true
        return [.refreshDisk(missing)]
      }

    case .disk(let sizes):
      diskBusy = false
      disk.merge(sizes) { _, new in new }
      diskAt = now
      if sortCol == .disk {
        applySort()
        reanchor()
      }

    case .procs(let udid, let result):
      guard udid == selUDID else { break }
      switch result {
      case .success(let list):
        procs = list
        procError = nil
      case .failure(let failure):
        procs = []
        procError = failure.message
      }
      sortProcs()
      if scroll >= procs.count { scroll = max(0, procs.count - 1) }
    }
    return []
  }

  mutating func key(_ key: TopKey) -> [TopEffect] {
    switch key {
    case .ctrlC, .character("q"):
      return [.quit]
    case .up, .character("k"):
      if screen == .fleet && cursor > 0 {
        cursor -= 1
        cursorUDID = sims[cursor].device.udid
      } else if screen == .drill && scroll > 0 {
        scroll -= 1
      }
    case .down, .character("j"):
      if screen == .fleet && cursor < sims.count - 1 {
        cursor += 1
        cursorUDID = sims[cursor].device.udid
      } else if screen == .drill && scroll < procs.count - 1 {
        scroll += 1
      }
    case .enter, .right, .character("l"):
      if screen == .fleet && cursor < sims.count {
        let sim = sims[cursor]
        screen = .drill
        selUDID = sim.device.udid
        selName = sim.device.name
        procs = []
        procError = nil
        scroll = 0
        return [.refreshProcs(selUDID)]
      }
    case .escape, .left, .character("h"):
      if screen == .drill {
        screen = .fleet
        selUDID = ""
        procs = []
      }
    case .character(let ch):
      if let column = topSortKeys[ch] {
        if screen == .drill && column != .ram && column != .cpu && column != .name { return [] }
        setSort(column)
      }
    }
    return []
  }

  /// Points the cursor back at the selected sim after a re-sort or refresh
  /// reorders (or removes) rows.
  mutating func reanchor() {
    if !cursorUDID.isEmpty {
      if let index = sims.firstIndex(where: { $0.device.udid == cursorUDID }) {
        cursor = index
        return
      }
      cursorUDID = ""
    }
    if cursor >= sims.count { cursor = max(0, sims.count - 1) }
  }

  /// Switches the sort column, or flips direction when the column is already
  /// active, then re-sorts the current view.
  mutating func setSort(_ column: TopSort) {
    if sortCol == column {
      sortDesc.toggle()
    } else {
      sortCol = column
      sortDesc = true
    }
    applySort()
    reanchor()
    sortProcs()
  }

  mutating func applySort() {
    let less: (TopSim, TopSim) -> Bool = { a, b in
      switch self.sortCol {
      case .cpu: return a.memory?.cpu ?? -1 < b.memory?.cpu ?? -1
      case .proc: return a.memory?.processes ?? -1 < b.memory?.processes ?? -1
      case .disk: return self.disk[a.device.udid] ?? 0 < self.disk[b.device.udid] ?? 0
      case .name: return a.device.name < b.device.name
      case .state: return a.managedDisabled ?? -1 < b.managedDisabled ?? -1
      case .os:
        if a.device.platformName != b.device.platformName {
          return a.device.platformName < b.device.platformName
        }
        return osLess(a.device.osVersion, b.device.osVersion)
      case .ram: return a.memory?.bytes ?? -1 < b.memory?.bytes ?? -1
      }
    }
    sims = stableSorted(sims, descending: sortDesc, less: less)
  }

  /// Only RAM, CPU and name apply to processes; other columns fall back to RAM so a
  /// fleet sort choice still behaves sensibly in the drill-down.
  mutating func sortProcs() {
    let less: (ProcessUsage, ProcessUsage) -> Bool = { a, b in
      switch self.sortCol {
      case .cpu: return a.cpu < b.cpu
      case .name: return a.command < b.command
      default: return a.bytes < b.bytes
      }
    }
    procs = stableSorted(procs, descending: sortDesc, less: less)
  }

  private func stableSorted<T>(_ items: [T], descending: Bool, less: (T, T) -> Bool) -> [T] {
    items.enumerated().sorted { a, b in
      let (x, y) = descending ? (b.element, a.element) : (a.element, b.element)
      if less(x, y) { return true }
      if less(y, x) { return false }
      return a.offset < b.offset
    }.map(\.element)
  }

  // MARK: - Rendering

  /// The screen, as lines. Styles are ANSI; every line is cut to the width.
  func screenLines() -> [String] {
    var lines = screen == .drill ? drillLines() : fleetLines()
    if width > 0 { lines = lines.map { fit($0, width) } }
    return lines
  }

  private static let bold = ("\u{1B}[1m", "\u{1B}[0m")
  private static let reverse = ("\u{1B}[7m", "\u{1B}[0m")
  private static let faint = ("\u{1B}[2m", "\u{1B}[0m")

  private func styled(_ style: (String, String), _ text: String) -> String {
    style.0 + text + style.1
  }

  /// Cuts a plain line to `limit` columns; styling is applied afterwards.
  private func fit(_ line: String, _ limit: Int) -> String {
    // Lines carry ANSI only at their ends, so cut the visible text in between.
    guard let open = line.range(of: "m"), line.hasPrefix("\u{1B}[") else {
      return String(String.UnicodeScalarView(line.unicodeScalars.prefix(limit)))
    }
    let prefix = String(line[..<open.upperBound])
    let reset = "\u{1B}[0m"
    var body = String(line[open.upperBound...])
    if body.hasSuffix(reset) { body = String(body.dropLast(reset.count)) }
    return prefix + String(String.UnicodeScalarView(body.unicodeScalars.prefix(limit))) + reset
  }

  func fleetLines() -> [String] {
    var lines = [styled(TopModel.bold, fleetHeader())]
    if let error, !loaded {
      lines.append(styled(TopModel.faint, error))
      return lines
    }
    if !loaded {
      lines.append(styled(TopModel.faint, "Loading booted simulators…"))
      return lines
    }
    if sims.isEmpty {
      lines.append(
        styled(TopModel.faint, "No booted simulators. Boot one with `simslim boot <udid>`."))
      return lines + footer()
    }

    let foot = footer()
    // Keep the cursor row on screen when there are more simulators than lines.
    var visible = sims.count
    var first = 0
    if height > 0 {
      visible = max(1, height - 1 - foot.count)
      if visible < sims.count {
        first = min(max(0, cursor - visible / 2), sims.count - visible)
      }
    }
    let nameWidth = self.nameWidth
    for index in first..<min(sims.count, first + visible) {
      let sim = sims[index]
      let row =
        padRight(
          truncate("\(sim.device.name) · \(shortUDID(sim.device.udid))", nameWidth), nameWidth)
        + " " + padRight(osLabel(sim), 14) + " " + padRight(stateLabel(sim), 6) + " "
        + padLeft(procCount(sim), 5) + " " + padLeft(cpuLabel(sim), 6) + " "
        + padLeft(ramLabel(sim), 8) + " " + padLeft(diskLabel(sim.device.udid), 8)
      lines.append(index == cursor ? styled(TopModel.reverse, row) : row)
    }
    return lines + foot
  }

  private func sortArrow(_ column: TopSort) -> String {
    sortCol == column ? (sortDesc ? "▼" : "▲") : ""
  }

  func fleetHeader() -> String {
    padRight("SIMULATOR" + sortArrow(.name), nameWidth) + " " + padRight("OS" + sortArrow(.os), 14)
      + " " + padRight("STATE" + sortArrow(.state), 6) + " "
      + padLeft("PROC" + sortArrow(.proc), 5) + " " + padLeft("CPU" + sortArrow(.cpu), 6) + " "
      + padLeft("RAM" + sortArrow(.ram), 8) + " " + padLeft("DISK" + sortArrow(.disk), 8)
  }

  /// OS(14)+STATE(6)+PROC(5)+CPU(6)+RAM(8)+DISK(8) + 6 separators.
  static let fleetFixedColumns = 53

  /// The SIMULATOR column flexes to fill the terminal: it grows when there is room
  /// and shrinks (down to a floor) when there is not.
  var nameWidth: Int {
    if width <= 0 { return 30 }  // no size yet
    return min(max(width - TopModel.fleetFixedColumns, 16), 60)
  }

  private func footer() -> [String] {
    let summary = "\(sims.count) booted · total \(fmtBytes(total))"
    let hint = "↑↓ select · ↵ open · sort n·o·s·p·c·m·d · q quit"
    var lines = [
      styled(TopModel.faint, String(repeating: "─", count: nameWidth + TopModel.fleetFixedColumns)),
      styled(TopModel.faint, summary + " · " + hint),
    ]
    if let error { lines.append(styled(TopModel.faint, "refresh error: " + error)) }
    return lines
  }

  func drillLines() -> [String] {
    let title = selName.isEmpty ? shortUDID(selUDID) : selName
    var lines = [styled(TopModel.bold, "\(title) — daemons by \(drillSortLabel)"), ""]
    if let procError {
      return lines + [
        styled(TopModel.faint, procError), "", styled(TopModel.faint, "esc back · q quit"),
      ]
    }
    if procs.isEmpty {
      return lines + [
        styled(TopModel.faint, "measuring…"), "", styled(TopModel.faint, "esc back · q quit"),
      ]
    }
    lines.append(
      styled(
        TopModel.bold,
        padLeft("RAM" + sortArrow(.ram), 8) + " " + padLeft("CPU" + sortArrow(.cpu), 6) + "  "
          + "COMMAND" + sortArrow(.name)))
    let rows = max(1, visibleRows)
    let start = clampScroll(scroll, procs.count, rows)
    let end = min(procs.count, start + rows)
    for p in procs[start..<end] {
      lines.append(
        padLeft(fmtBytes(p.bytes), 8) + " " + padLeft(String(format: "%.1f", p.cpu), 5) + "%  "
          + p.command)
    }
    lines.append(
      styled(
        TopModel.faint,
        "\(start + 1)–\(end) of \(procs.count) · ↑↓ scroll · sort m·c·n · esc back · q quit"))
    return lines
  }

  /// The drill-down's effective sort column (fleet-only columns fall back to RAM).
  var drillSortLabel: String {
    switch sortCol {
    case .cpu: return "CPU"
    case .name: return "command"
    default: return "RAM"
    }
  }

  /// The process-list height: total minus title, blank, header, footer.
  var visibleRows: Int { height == 0 ? 20 : height - 5 }

  // MARK: - Labels

  func stateLabel(_ sim: TopSim) -> String {
    guard sim.statusError.isEmpty, let disabled = sim.managedDisabled else { return "?" }
    if disabled == sim.managedTotal { return "slim" }
    return disabled > 0 ? "part" : "stock"
  }

  func osLabel(_ sim: TopSim) -> String {
    sim.device.osVersion.isEmpty ? "?" : truncate(sim.device.runtimeName, 14)
  }

  func procCount(_ sim: TopSim) -> String {
    sim.memory.map { String($0.processes) } ?? "—"
  }

  func cpuLabel(_ sim: TopSim) -> String {
    sim.memory.map { String(format: "%.0f%%", $0.cpu) } ?? "—"
  }

  func ramLabel(_ sim: TopSim) -> String {
    if let memory = sim.memory { return fmtBytes(memory.bytes) }
    return sim.memoryError.isEmpty ? "—" : "err"
  }

  func diskLabel(_ udid: String) -> String {
    disk[udid].map(fmtBytes) ?? "…"
  }
}

// MARK: - Shared formatting

/// Pads on the left to `width`, counting Unicode scalars like Go's `%Ns`.
func padLeft(_ text: String, _ width: Int) -> String {
  let count = text.unicodeScalars.count
  return count >= width ? text : String(repeating: " ", count: width - count) + text
}

/// Binary units with one decimal: "512B", "1.5K", "14.2G".
func fmtBytes(_ bytes: Int64) -> String {
  let unit: Int64 = 1024
  if bytes < unit { return "\(bytes)B" }
  var div = unit
  var exp = 0
  var n = bytes / unit
  while n >= unit {
    div *= unit
    exp += 1
    n /= unit
  }
  let suffix = Array("KMGTPE")[exp]
  return String(format: "%.1f", Double(bytes) / Double(div)) + String(suffix)
}

func shortUDID(_ udid: String) -> String {
  udid.unicodeScalars.count > 8
    ? String(String.UnicodeScalarView(udid.unicodeScalars.prefix(8))) : udid
}

func clampScroll(_ scroll: Int, _ total: Int, _ rows: Int) -> Int {
  if scroll < 0 { return 0 }
  if scroll > total - rows { return max(0, total - rows) }
  return scroll
}

/// Compares dotted version strings numerically ("9.0" < "26.4", which lexical
/// order gets wrong). Non-numeric segments compare lexically; a missing version
/// sorts first.
func osLess(_ a: String, _ b: String) -> Bool {
  let left = a.split(separator: ".", omittingEmptySubsequences: false)
  let right = b.split(separator: ".", omittingEmptySubsequences: false)
  for i in 0..<min(left.count, right.count) {
    if let x = Int(left[i]), let y = Int(right[i]) {
      if x != y { return x < y }
      continue
    }
    if left[i] != right[i] { return left[i] < right[i] }
  }
  return left.count < right.count
}

// MARK: - One-shot output, for a pipe or --json

func staticFleet(_ out: TopOutput) -> String {
  var text =
    padRight("SIMULATOR", 30) + " " + padRight("OS", 14) + " " + padRight("STATE", 6) + " "
    + padLeft("PROC", 5) + " " + padLeft("CPU", 6) + " " + padLeft("RAM", 8) + "\n"
  let labels = TopModel()
  for sim in out.sims {
    text +=
      padRight(truncate("\(sim.device.name) · \(shortUDID(sim.device.udid))", 30), 30) + " "
      + padRight(labels.osLabel(sim), 14) + " " + padRight(labels.stateLabel(sim), 6) + " "
      + padLeft(labels.procCount(sim), 5) + " " + padLeft(labels.cpuLabel(sim), 6) + " "
      + padLeft(labels.ramLabel(sim), 8) + "\n"
  }
  return text + "\(out.sims.count) booted · total \(fmtBytes(out.totalBytes))\n"
}

func staticProcs(_ top: TopProcesses) -> String {
  let name = top.name.isEmpty ? shortUDID(top.udid) : top.name
  var text =
    "\(name) — daemons by RAM\n" + padLeft("RAM", 8) + " " + padLeft("CPU", 6) + "  COMMAND\n"
  for p in top.processes {
    text +=
      padLeft(fmtBytes(p.bytes), 8) + " " + padLeft(String(format: "%.1f", p.cpu), 5)
      + "%  " + p.command + "\n"
  }
  return text
}
