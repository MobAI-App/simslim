// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// The RuntimeRoot directories holding the job plists launchd_sim bootstraps
/// into the simulator's system domain.
let launchdJobDirs = ["System/Library/LaunchDaemons", "System/Library/LaunchAgents"]

/// Bounds how many plist paths go into one `launchctl unload`, so the argument
/// list stays far below ARG_MAX however long the profile grows.
let unloadChunk = 64

/// Reads `launchctl list` rows: "PID<TAB>Status<TAB>Label", with "-" as the PID
/// of a loaded job that is not running.
func parseLaunchctlList(_ output: String) -> Set<String> {
  var loaded = Set<String>()
  for line in output.split(whereSeparator: \.isNewline) {
    let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
    if fields.count != 3 || fields[2] == "Label" { continue }
    loaded.insert(String(fields[2]))
  }
  return loaded
}

/// Keeps the labels the batch did not finish: no disable override yet, or still
/// loaded. A few jobs stay listed even with their override in place, so they
/// always take the per-label bootout.
func stillToStop(_ labels: [String], disabled: Set<String>, loaded: Set<String>) -> [String] {
  labels.filter { !disabled.contains($0) || loaded.contains($0) }
}

extension Simctl {
  /// Reads a job plist's Label with the host's plutil, which handles both XML
  /// and binary plists.
  func readPlistLabel(path: String) throws -> String {
    let result = try exec(.plutil, ["-extract", "Label", "raw", "-o", "-", path])
    guard result.succeeded else {
      throw SimSlimError("plutil: exit status \(result.status): \(result.combinedText)")
    }
    return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Maps each label to the job plist that defines exactly that label. A plist
  /// is used only when its own Label key matches, so a renamed or shared file
  /// can never unload a daemon outside the allowlist.
  func launchdJobPlists(root: String, labels: [String], plistLabel: (String) throws -> String)
    -> [String: String]
  {
    var paths: [String: String] = [:]
    for label in labels {
      if deadlineExpired { break }
      for dir in launchdJobDirs {
        let path = ((root as NSString).appendingPathComponent(dir) as NSString)
          .appendingPathComponent(label + ".plist")
        guard FileManager.default.fileExists(atPath: path) else { continue }
        if let got = try? plistLabel(path), got == label {
          paths[label] = path
          break
        }
      }
    }
    return paths
  }

  /// Every label currently loaded in the simulator's launchd.
  func loadedLabels(set: String, udid: String) throws -> Set<String> {
    parseLaunchctlList(try readLaunchd(set: set, udid: udid, ["list"]))
  }

  /// One `launchctl <verb> -w` spawn per chunk of plists. The exit status is not
  /// trusted: launchctl reports any single failure for the whole call, so the
  /// caller reads the state back. A chunk that runs out of time ends the batch,
  /// so a slow host keeps the rest of its budget for the per-label path.
  func batchJobs(set: String, udid: String, verb: String, paths: [String]) {
    var start = 0
    while start < paths.count {
      let end = min(start + unloadChunk, paths.count)
      let args = simctlArgs(
        set: set, ["spawn", udid, "launchctl", verb, "-w"] + Array(paths[start..<end]))
      let result = try? exec(.xcrun, args, timeout: spawnTimeout)
      if result == nil || result!.timedOut { return }
      start = end
    }
  }

  func unloadJobs(set: String, udid: String, paths: [String]) {
    batchJobs(set: set, udid: udid, verb: "unload", paths: paths)
  }

  /// The labels still enabled or still loaded.
  func stopState(set: String, udid: String, labels: [String]) throws -> [String] {
    let disabled = try readDisabled(set: set, udid: udid)
    let loaded = try loadedLabels(set: set, udid: udid)
    return stillToStop(labels, disabled: disabled, loaded: loaded)
  }
}
