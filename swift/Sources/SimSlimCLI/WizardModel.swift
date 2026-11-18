// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit

// The `simslim profile` checklist as a pure state machine: keys in, screen lines
// out. The terminal side (raw mode, reading bytes) lives in WizardTerminal.swift.

struct WizardModel {
  enum Screen: Equatable {
    case features
    case daemons(Int)  // index into Catalog.categories
  }

  enum Outcome: Equatable {
    case running, saved, cancelled
  }

  let categories: [SimSlimKit.Category]
  var screen: Screen = .features
  var except: Set<String> = []
  var keep: Set<String> = []
  var cursor = 0
  var top = 0
  var termRows: Int
  private(set) var outcome: Outcome = .running

  init(categories: [SimSlimKit.Category] = Catalog.categories, termRows: Int = 24) {
    self.categories = categories
    self.termRows = termRows
  }

  private var rowCount: Int {
    switch screen {
    case .features: return categories.count
    case .daemons(let i): return categories[i].labels.count
    }
  }

  private var headerLines: [String] {
    switch screen {
    case .features:
      return [
        "Features to keep enabled — everything unchecked is slimmed.",
        "[x] whole feature kept · [~] some daemons kept",
      ]
    case .daemons(let i):
      return [
        categories[i].name + " — keep individual daemons enabled.",
        "Unchecked daemons in this feature are slimmed.",
      ]
    }
  }

  private var footer: String {
    switch screen {
    case .features:
      return
        "↑/↓ move · space keep feature · → pick daemons · a all · n none · enter save · q cancel"
    case .daemons:
      return "↑/↓ move · space keep daemon · a all · n none · ← back · q cancel"
    }
  }

  private var visible: Int { max(3, termRows - headerLines.count - 2) }

  mutating func key(_ key: TopKey) {
    guard outcome == .running else { return }
    switch screen {
    case .features: featureKey(key)
    case .daemons(let i): daemonKey(key, category: categories[i])
    }
    scroll()
  }

  private mutating func move(_ delta: Int) {
    cursor = min(max(cursor + delta, 0), rowCount - 1)
  }

  private mutating func featureKey(_ key: TopKey) {
    switch key {
    case .up, .character("k"): move(-1)
    case .down, .character("j"): move(1)
    case .enter: outcome = .saved
    case .ctrlC, .character("q"), .character("Q"): outcome = .cancelled
    case .character(" "): toggle(&except, categories[cursor].id)
    case .right, .character("l"):
      screen = .daemons(cursor)
      cursor = 0
      top = 0
    case .character("a"), .character("A"):
      for c in categories { except.insert(c.id) }
    case .character("n"), .character("N"): except = []
    default: break
    }
  }

  private mutating func daemonKey(_ key: TopKey, category: SimSlimKit.Category) {
    switch key {
    case .up, .character("k"): move(-1)
    case .down, .character("j"): move(1)
    case .left, .enter, .character("h"), .character("q"), .character("Q"):
      guard case .daemons(let i) = screen else { return }
      screen = .features
      cursor = i
      top = 0
    case .ctrlC: outcome = .cancelled
    case .character(" "): toggle(&keep, category.labels[cursor])
    case .character("a"), .character("A"):
      for l in category.labels { keep.insert(l) }
    case .character("n"), .character("N"):
      for l in category.labels { keep.remove(l) }
    default: break
    }
  }

  private func toggle(_ set: inout Set<String>, _ value: String) {
    if set.contains(value) { set.remove(value) } else { set.insert(value) }
  }

  private mutating func scroll() {
    let total = rowCount
    if total <= visible {
      top = 0
      return
    }
    if cursor < top { top = cursor }
    if cursor >= top + visible { top = cursor - visible + 1 }
    top = max(0, min(top, total - visible))
  }

  func rows() -> [String] {
    switch screen {
    case .features:
      return categories.map { c in
        var box = "[ ]"
        var suffix = ""
        if except.contains(c.id) {
          box = "[x]"
        } else {
          let n = c.labels.filter { keep.contains($0) }.count
          if n > 0 {
            box = "[~]"
            suffix = "  (\(n) kept)"
          }
        }
        return "\(box) \(padRight(c.id, 14)) \(c.name)\(suffix)"
      }
    case .daemons(let i):
      let c = categories[i]
      return c.labels.map { label in
        let box = keep.contains(label) ? "[x]" : "[ ]"
        if let desc = c.serviceDescriptions[label], !desc.isEmpty {
          return truncate("\(box) \(padRight(label, 44)) \(desc)", 76)
        }
        return truncate("\(box) \(label)", 76)
      }
    }
  }

  /// The full frame, lines separated for a raw terminal ("\r\n" joins them).
  func frame() -> String {
    let all = rows()
    let end = min(top + visible, all.count)
    var out = "\u{1B}[H\u{1B}[J"
    for h in headerLines { out += h + "\r\n" }
    for i in top..<end { out += (i == cursor ? "❯ " : "  ") + all[i] + "\r\n" }
    var more = ""
    if top > 0 { more += " ↑more" }
    if end < all.count { more += " ↓more" }
    return out + "\r\n" + footer + more
  }

  /// What the wizard produced: whole features in catalog order, and kept daemons
  /// that no kept feature already covers, each once, in catalog order.
  func selection() -> (except: [String], keep: [String]) {
    let exceptIDs = categories.filter { except.contains($0.id) }.map { $0.id }
    let covered = Set(categories.filter { except.contains($0.id) }.flatMap { $0.labels })
    var keptLabels: [String] = []
    var seen = Set<String>()
    for c in categories where !except.contains(c.id) {
      for l in c.labels where keep.contains(l) && !covered.contains(l) && seen.insert(l).inserted {
        keptLabels.append(l)
      }
    }
    return (exceptIDs, keptLabels)
  }
}
