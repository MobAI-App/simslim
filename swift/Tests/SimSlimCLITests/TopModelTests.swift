import SimSlimKit
import XCTest

@testable import SimSlimCLI

final class TopModelTests: XCTestCase {
  private func sim(
    _ n: Int, name: String? = nil, ram: Int64? = nil, cpu: Double = 0, procs: Int = 10,
    disabled: Int? = 173, os: String = "27.2", platform: String = "iOS"
  ) -> TopSim {
    TopSim(
      device: Device(
        udid: String(format: "AAAAAAAA-0000-0000-0000-%012d", n), name: name ?? "Sim \(n)",
        state: "Booted", platform: platform, osVersion: os, set: "default"),
      managedDisabled: disabled, managedTotal: 173,
      memory: ram.map { MemoryMeasurement(processes: procs, bytes: $0, cpu: cpu) })
  }

  private func loaded(_ sims: [TopSim], width: Int = 100, height: Int = 30) -> TopModel {
    var model = TopModel()
    _ = model.apply(.resize(width: width, height: height), now: Date())
    _ = model.apply(
      .fleet(
        .success(
          TopOutput(sims: sims, totalBytes: sims.compactMap { $0.memory?.bytes }.reduce(0, +)))),
      now: Date())
    return model
  }

  // MARK: - fleet updates

  func testTheFirstSnapshotLoadsAndRequestsDiskForEverySimulator() {
    var model = TopModel()
    let effects = model.apply(
      .fleet(.success(TopOutput(sims: [sim(1, ram: 5), sim(2, ram: 9)], totalBytes: 14))),
      now: Date())
    XCTAssertTrue(model.loaded)
    XCTAssertEqual(model.sims.map(\.device.name), ["Sim 2", "Sim 1"], "sorted by RAM, descending")
    XCTAssertEqual(
      effects, [.refreshDisk(model.sims.map { $0.device.udid })],
      "disk is measured for the new ones")
    XCTAssertTrue(model.diskBusy)
    // Not again while a sweep is in flight.
    XCTAssertEqual(model.apply(.fleet(.success(TopOutput(sims: model.sims))), now: Date()), [])
  }

  func testAFailedRefreshKeepsThePreviousSnapshotAndShowsTheError() {
    var model = loaded([sim(1, ram: 5)])
    _ = model.apply(.fleet(.failure(SimSlimError("simctl list: boom"))), now: Date())
    XCTAssertEqual(model.sims.count, 1)
    XCTAssertTrue(model.screenLines().joined().contains("refresh error: simctl list: boom"))
    _ = model.apply(.fleet(.success(TopOutput(sims: model.sims))), now: Date())
    XCTAssertNil(model.error, "a good refresh clears it")
  }

  func testAnErrorBeforeTheFirstSnapshotIsTheOnlyThingShown() {
    var model = TopModel()
    _ = model.apply(.fleet(.failure(SimSlimError("no xcode"))), now: Date())
    XCTAssertTrue(model.screenLines().joined(separator: "\n").contains("no xcode"))
    XCTAssertFalse(model.loaded)
  }

  func testLoadingAndEmptyMessages() {
    var model = TopModel()
    XCTAssertTrue(model.screenLines().joined().contains("Loading booted simulators…"))
    _ = model.apply(.fleet(.success(TopOutput())), now: Date())
    XCTAssertTrue(
      model.screenLines().joined().contains(
        "No booted simulators. Boot one with `simslim boot <udid>`."))
  }

  func testDiskIsRefreshedOnlyAfterItsTTL() {
    var model = loaded([sim(1, ram: 5)])
    let start = Date()
    _ = model.apply(.disk([model.sims[0].device.udid: 100]), now: start)
    XCTAssertFalse(model.diskBusy)
    XCTAssertEqual(model.tick(now: start.addingTimeInterval(topDiskTTL - 1)), [.refreshFleet])
    let late = model.tick(now: start.addingTimeInterval(topDiskTTL + 1))
    XCTAssertEqual(late, [.refreshFleet, .refreshDisk([model.sims[0].device.udid])])
    XCTAssertTrue(model.diskBusy)
    XCTAssertEqual(model.tick(now: start.addingTimeInterval(topDiskTTL + 5)), [.refreshFleet])
  }

  // MARK: - sorting and the cursor

  func testSortKeysChooseAndFlipTheColumn() {
    var model = loaded([
      sim(1, name: "b", ram: 5, cpu: 30), sim(2, name: "a", ram: 9, cpu: 10),
      sim(3, name: "c", ram: 1, cpu: 20),
    ])
    XCTAssertEqual(model.sims.map(\.device.name), ["a", "b", "c"], "RAM, descending")
    _ = model.key(.character("c"))
    XCTAssertEqual(model.sims.map(\.device.name), ["b", "c", "a"], "CPU, descending")
    _ = model.key(.character("c"))
    XCTAssertEqual(model.sims.map(\.device.name), ["a", "c", "b"], "again flips to ascending")
    _ = model.key(.character("n"))
    XCTAssertEqual(model.sims.map(\.device.name), ["c", "b", "a"], "name, descending first")
    _ = model.key(.character("m"))
    XCTAssertEqual(model.sims.map(\.device.name), ["a", "b", "c"])
    XCTAssertTrue(model.screenLines()[0].contains("RAM▼"))
  }

  func testSortByOSComparesVersionsNumerically() {
    var model = loaded([
      sim(1, name: "old", ram: 1, os: "9.0"), sim(2, name: "new", ram: 1, os: "26.4"),
      sim(3, name: "tv", ram: 1, os: "26.4", platform: "tvOS"),
    ])
    _ = model.key(.character("o"))
    XCTAssertEqual(model.sims.map(\.device.name), ["tv", "new", "old"], "platform, then version")
    XCTAssertTrue(osLess("9.0", "26.4"))
    XCTAssertFalse(osLess("26.4", "9.0"))
    XCTAssertTrue(osLess("26", "26.1"))
    XCTAssertTrue(osLess("", "1"))
  }

  func testStateAndProcessAndDiskSorts() {
    var model = loaded([
      sim(1, name: "stock", ram: 1, procs: 5, disabled: 0),
      sim(2, name: "slim", ram: 2, procs: 99, disabled: 173),
      sim(3, name: "unknown", ram: 3, procs: 50, disabled: nil),
    ])
    _ = model.key(.character("s"))
    XCTAssertEqual(model.sims.map(\.device.name), ["slim", "stock", "unknown"])
    _ = model.key(.character("p"))
    XCTAssertEqual(model.sims.map(\.device.name), ["slim", "unknown", "stock"])
    _ = model.apply(
      .disk([model.sims[0].device.udid: 1, model.sims[2].device.udid: 9]), now: Date())
    _ = model.key(.character("d"))
    XCTAssertEqual(model.sims[0].device.udid, String(format: "AAAAAAAA-0000-0000-0000-%012d", 1))
  }

  func testASimulatorWithoutAMeasurementSortsLastByRAM() {
    let model = loaded([sim(1, ram: nil), sim(2, ram: 5), sim(3, ram: 1)])
    XCTAssertEqual(model.sims.map(\.device.name), ["Sim 2", "Sim 3", "Sim 1"])
  }

  func testTheCursorFollowsItsSimulatorAcrossRefreshesAndResorts() {
    var model = loaded([sim(1, ram: 5), sim(2, ram: 9), sim(3, ram: 1)])
    _ = model.key(.down)  // Sim 1 (second by RAM)
    XCTAssertEqual(model.sims[model.cursor].device.name, "Sim 1")
    // Sim 3 balloons and moves to the top; the cursor stays on Sim 1.
    _ = model.apply(
      .fleet(.success(TopOutput(sims: [sim(1, ram: 5), sim(2, ram: 9), sim(3, ram: 50)]))),
      now: Date())
    XCTAssertEqual(model.sims.map(\.device.name), ["Sim 3", "Sim 2", "Sim 1"])
    XCTAssertEqual(model.sims[model.cursor].device.name, "Sim 1")
    // It disappears: the cursor stays in range.
    _ = model.apply(.fleet(.success(TopOutput(sims: [sim(2, ram: 9)]))), now: Date())
    XCTAssertEqual(model.cursor, 0)
  }

  func testACursorWhoseSimulatorLeftDoesNotJumpBackWhenItReturns() {
    var model = loaded([sim(1, ram: 5), sim(2, ram: 9), sim(3, ram: 1)])
    _ = model.key(.down)
    _ = model.key(.down)  // Sim 3, last
    XCTAssertEqual(model.sims[model.cursor].device.name, "Sim 3")
    _ = model.apply(
      .fleet(.success(TopOutput(sims: [sim(1, ram: 5), sim(2, ram: 9)]))), now: Date())
    XCTAssertEqual(model.cursor, 1, "clamped into range")
    // It returns as the biggest; the old anchor is gone, so the cursor stays put.
    _ = model.apply(
      .fleet(.success(TopOutput(sims: [sim(1, ram: 5), sim(2, ram: 9), sim(3, ram: 99)]))),
      now: Date())
    XCTAssertEqual(model.sims.map(\.device.name), ["Sim 3", "Sim 2", "Sim 1"])
    XCTAssertEqual(model.cursor, 1)
  }

  func testScrollIsPulledBackWhenTheProcessListShrinks() {
    var model = loaded([sim(1, ram: 5)], height: 8)
    _ = model.key(.enter)
    let big = (1...10).map {
      ProcessUsage(pid: $0, command: "p\($0)", bytes: Int64(100 - $0), cpu: 0)
    }
    _ = model.apply(.procs(udid: model.selUDID, .success(big)), now: Date())
    for _ in 0..<9 { _ = model.key(.down) }
    XCTAssertEqual(model.scroll, 9)
    _ = model.apply(.procs(udid: model.selUDID, .success(Array(big.prefix(3)))), now: Date())
    XCTAssertEqual(model.scroll, 2)
  }

  func testCursorKeysStayInRange() {
    var model = loaded([sim(1, ram: 5), sim(2, ram: 9)])
    _ = model.key(.up)
    XCTAssertEqual(model.cursor, 0)
    _ = model.key(.down)
    _ = model.key(.down)
    _ = model.key(.character("j"))
    XCTAssertEqual(model.cursor, 1)
    _ = model.key(.character("k"))
    XCTAssertEqual(model.cursor, 0)
  }

  // MARK: - drill-down

  func testEnterOpensTheDrillDownAndEscapeGoesBack() {
    var model = loaded([sim(1, name: "Phone", ram: 5)])
    let effects = model.key(.enter)
    XCTAssertEqual(effects, [.refreshProcs(model.sims[0].device.udid)])
    XCTAssertEqual(model.screen, .drill)
    XCTAssertEqual(model.selName, "Phone")
    XCTAssertTrue(model.screenLines().joined().contains("measuring…"))
    _ = model.key(.escape)
    XCTAssertEqual(model.screen, .fleet)
    XCTAssertEqual(model.selUDID, "")
  }

  func testProcessResultsOnlyCountForTheOpenSimulator() {
    var model = loaded([sim(1, ram: 5)])
    _ = model.key(.enter)
    let id = model.selUDID
    _ = model.apply(
      .procs(
        udid: "someone-else", .success([ProcessUsage(pid: 1, command: "x", bytes: 1, cpu: 0)])),
      now: Date())
    XCTAssertEqual(model.procs, [])
    _ = model.apply(
      .procs(
        udid: id,
        .success([
          ProcessUsage(pid: 1, command: "launchd_sim", bytes: 1 << 20, cpu: 0.5),
          ProcessUsage(pid: 2, command: "SpringBoard", bytes: 300 << 20, cpu: 2),
        ])),
      now: Date())
    XCTAssertEqual(model.procs.map(\.command), ["SpringBoard", "launchd_sim"])
    let text = model.screenLines().joined(separator: "\n")
    XCTAssertTrue(
      text.contains("Phone — daemons by RAM") || text.contains("Sim 1 — daemons by RAM"))
    XCTAssertTrue(text.contains("300.0M   2.0%  SpringBoard"), text)
    XCTAssertTrue(text.contains("1–2 of 2"))
  }

  func testDrillSortsOnlyOfferRAMCPUAndName() {
    var model = loaded([sim(1, ram: 5)])
    _ = model.key(.enter)
    _ = model.apply(
      .procs(
        udid: model.selUDID,
        .success([
          ProcessUsage(pid: 1, command: "b", bytes: 5, cpu: 1),
          ProcessUsage(pid: 2, command: "a", bytes: 9, cpu: 3),
        ])),
      now: Date())
    _ = model.key(.character("d"))  // a fleet-only column: ignored here
    XCTAssertEqual(model.sortCol, .ram)
    _ = model.key(.character("c"))
    XCTAssertEqual(model.procs.map(\.command), ["a", "b"])
    _ = model.key(.character("n"))
    XCTAssertEqual(model.procs.map(\.command), ["b", "a"], "name, descending")
    XCTAssertTrue(model.screenLines()[0].contains("daemons by command"))
  }

  func testDrillScrollingIsClamped() {
    var model = loaded([sim(1, ram: 5)], height: 8)  // 3 visible process rows
    _ = model.key(.enter)
    let procs = (1...10).map {
      ProcessUsage(pid: $0, command: "p\($0)", bytes: Int64(100 - $0), cpu: 0)
    }
    _ = model.apply(.procs(udid: model.selUDID, .success(procs)), now: Date())
    for _ in 0..<50 { _ = model.key(.down) }
    XCTAssertEqual(model.scroll, 9)
    let lines = model.screenLines()
    XCTAssertTrue(lines.last!.contains("8–10 of 10"), lines.last!)
    for _ in 0..<50 { _ = model.key(.up) }
    XCTAssertEqual(model.scroll, 0)
  }

  func testAProcessErrorIsShownWithTheWayBack() {
    var model = loaded([sim(1, ram: 5)])
    _ = model.key(.enter)
    _ = model.apply(
      .procs(udid: model.selUDID, .failure(SimSlimError("simulator does not appear to be booted"))),
      now: Date())
    let text = model.screenLines().joined(separator: "\n")
    XCTAssertTrue(text.contains("does not appear to be booted"))
    XCTAssertTrue(text.contains("esc back · q quit"))
  }

  func testStartingInsideADrillDown() {
    var model = TopModel(drillInto: "UDID-1", name: "Phone")
    XCTAssertEqual(model.start(), [.refreshFleet, .refreshProcs("UDID-1")])
    XCTAssertEqual(model.screen, .drill)
    XCTAssertEqual(model.tick(now: Date()), [.refreshFleet, .refreshProcs("UDID-1")])
    var fleet = TopModel()
    XCTAssertEqual(fleet.start(), [.refreshFleet])
  }

  func testQuitKeys() {
    for key in [TopKey.ctrlC, .character("q")] {
      var model = TopModel()
      XCTAssertEqual(model.key(key), [.quit])
    }
  }

  // MARK: - rendering

  func testTheFleetTableLayout() {
    var model = loaded([sim(1, name: "iPhone 17", ram: 6_800_000_000, cpu: 136, procs: 90)])
    _ = model.apply(.disk([model.sims[0].device.udid: 7_000_000_000]), now: Date())
    let lines = model.screenLines()
    XCTAssertTrue(lines[0].hasPrefix("\u{1B}[1mSIMULATOR"))
    XCTAssertTrue(lines[0].contains("RAM▼"))
    XCTAssertTrue(lines[1].hasPrefix("\u{1B}[7m"), "the selected row is reversed")
    XCTAssertTrue(lines[1].contains("iPhone 17 · AAAAAAAA"))
    XCTAssertTrue(lines[1].contains("iOS 27.2"))
    XCTAssertTrue(lines[1].contains("slim"))
    XCTAssertTrue(lines[1].contains("90"))
    XCTAssertTrue(lines[1].contains("136%"))
    XCTAssertTrue(lines[1].contains("6.3G"))
    XCTAssertTrue(lines[1].contains("6.5G"))
    XCTAssertTrue(lines.joined().contains("1 booted · total 6.3G"))
    XCTAssertTrue(lines.joined().contains("↑↓ select · ↵ open · sort n·o·s·p·c·m·d · q quit"))
  }

  func testEveryLineFitsTheTerminalWidth() {
    for width in [20, 40, 80, 120] {
      var model = loaded(
        [sim(1, name: "A rather long simulator name that goes on", ram: 5)], width: width)
      _ = model.key(.enter)
      for screen in [TopModel.Screen.fleet, .drill] {
        model.screen = screen
        for line in model.screenLines() {
          let visible = line.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
          XCTAssertLessThanOrEqual(visible.unicodeScalars.count, width, "\(screen) at \(width)")
        }
      }
    }
  }

  func testTheNameColumnFlexesWithTheTerminal() {
    var model = TopModel()
    XCTAssertEqual(model.nameWidth, 30)
    model.width = 60
    XCTAssertEqual(model.nameWidth, 16)
    model.width = 100
    XCTAssertEqual(model.nameWidth, 47)
    model.width = 400
    XCTAssertEqual(model.nameWidth, 60)
  }

  func testTheCursorRowStaysVisibleWhenThereAreMoreSimulatorsThanLines() {
    let sims = (1...30).map { sim($0, ram: Int64(1000 - $0)) }
    var model = loaded(sims, height: 10)
    for _ in 0..<20 { _ = model.key(.down) }
    let lines = model.screenLines()
    XCTAssertLessThanOrEqual(lines.count, 10)
    XCTAssertTrue(lines.contains { $0.hasPrefix("\u{1B}[7m") }, "the selected row is on screen")
  }

  func testStatusAndMemoryLabels() {
    let model = TopModel()
    XCTAssertEqual(model.stateLabel(sim(1, disabled: 173)), "slim")
    XCTAssertEqual(model.stateLabel(sim(1, disabled: 5)), "part")
    XCTAssertEqual(model.stateLabel(sim(1, disabled: 0)), "stock")
    XCTAssertEqual(model.stateLabel(sim(1, disabled: nil)), "?")
    var broken = sim(1)
    broken.statusError = "boom"
    XCTAssertEqual(model.stateLabel(broken), "?")
    XCTAssertEqual(model.ramLabel(sim(1, ram: nil)), "—")
    var failed = sim(1)
    failed.memoryError = "x"
    XCTAssertEqual(model.ramLabel(failed), "err")
    XCTAssertEqual(model.procCount(sim(1, ram: nil)), "—")
    XCTAssertEqual(model.cpuLabel(sim(1, ram: nil)), "—")
    XCTAssertEqual(model.osLabel(sim(1, os: "")), "?")
    XCTAssertEqual(model.diskLabel("nope"), "…")
  }

  func testFormatting() {
    XCTAssertEqual(fmtBytes(0), "0B")
    XCTAssertEqual(fmtBytes(1023), "1023B")
    XCTAssertEqual(fmtBytes(1024), "1.0K")
    XCTAssertEqual(fmtBytes(1536), "1.5K")
    XCTAssertEqual(fmtBytes(10 << 20), "10.0M")
    XCTAssertEqual(fmtBytes(14_740_000_000), "13.7G")
    XCTAssertEqual(fmtBytes(Int64(5) << 40), "5.0T")
    XCTAssertEqual(fmtBytes(Int64.max), "8.0E")
    XCTAssertEqual(shortUDID("ABCDEFGH-1234"), "ABCDEFGH")
    XCTAssertEqual(shortUDID("short"), "short")
    XCTAssertEqual(padLeft("ab", 5), "   ab")
    XCTAssertEqual(padLeft("abcdef", 5), "abcdef")
    XCTAssertEqual(clampScroll(-3, 10, 4), 0)
    XCTAssertEqual(clampScroll(99, 10, 4), 6)
    XCTAssertEqual(clampScroll(3, 2, 4), 0)
  }

  // MARK: - keys

  func testKeyParsing() {
    XCTAssertEqual(parseTopKeys([0x71]), [.character("q")])
    XCTAssertEqual(parseTopKeys([0x1B, 0x5B, 0x41]), [.up])
    XCTAssertEqual(
      parseTopKeys([0x1B, 0x5B, 0x42, 0x1B, 0x5B, 0x43, 0x1B, 0x5B, 0x44]), [.down, .right, .left])
    XCTAssertEqual(parseTopKeys([0x1B, 0x4F, 0x41]), [.up], "application-mode arrows")
    XCTAssertEqual(parseTopKeys([0x1B]), [.escape])
    XCTAssertEqual(parseTopKeys([0x0D]), [.enter])
    XCTAssertEqual(parseTopKeys([0x03]), [.ctrlC])
    XCTAssertEqual(parseTopKeys([0x6A, 0x6A]), [.character("j"), .character("j")])
    XCTAssertEqual(parseTopKeys([0xC3, 0xA9]), [], "UTF-8 is ignored")
    XCTAssertEqual(parseTopKeys([]), [])
  }
}
