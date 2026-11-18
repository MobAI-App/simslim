// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation
import SimSlimKit

// The read-only commands. Each returns the exit status; an error is reported by
// the caller as `simslim: <message>` with status 1.

extension CLI {
  func cmdList(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    guard context.parsed.positionals.isEmpty else {
      throw SimSlimError("list takes no arguments")
    }
    let simctl = context.simctl
    var devices = try simctl.listDevices()
    if context.parsed.bool("booted") { devices = devices.filter { $0.state == "Booted" } }
    devices.sort { a, b in
      if a.platformName != b.platformName { return a.platformName < b.platformName }
      if a.osVersion != b.osVersion { return a.osVersion > b.osVersion }
      if a.name != b.name { return a.name < b.name }
      return a.udid < b.udid
    }

    var memory: [String: MemoryMeasurement] = [:]
    var memoryErrors: [String: String] = [:]
    if json {
      let booted = devices.filter { $0.state == "Booted" }.map(\.udid)
      (memory, memoryErrors) = simctl.measureMany(udids: booted)
    }

    var summaries: [DeviceSummary] = []
    for device in devices {
      let managed = Profile().desired(for: device).count
      var tag = "shutdown"
      var summary = DeviceSummary(device: device, managedTotal: managed)
      if device.state == "Booted" {
        tag = "booted"
        summary.memory = memory[device.udid]
        summary.memoryError = memoryErrors[device.udid] ?? ""
        do {
          let status = try simctl.readStatus(for: device).status
          tag = "booted · \(status.managedDisabled)/\(managed) slim"
          summary.managedDisabled = status.managedDisabled
        } catch {
          summary.statusError = error.localizedDescription
        }
      }
      summaries.append(summary)
      if !json {
        var line =
          "\(device.udid)  \(padRight(truncate(device.name, 22), 22)) "
          + "\(padRight(device.runtimeName, 14)) \(tag)"
        if !device.set.isEmpty && device.set != "default" { line += "  (\(device.set))" }
        context.stdout(line + "\n")
      }
    }
    if json { context.stdout(try jsonText(summaries)) }
    return 0
  }

  func cmdProfiles(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let args = context.parsed.positionals
    guard args.count <= 1 else {
      throw SimSlimError("profiles takes at most one category ID (see `simslim profiles`)")
    }
    let out = context.stdout

    if let id = args.first {
      guard let category = Catalog.category(id: id) else {
        throw SimSlimError("unknown category \"\(id)\" (see `simslim profiles`)")
      }
      if json {
        out(try jsonText(category))
        return 0
      }
      out("\(padRight(category.id, 14)) \(category.name)\n")
      out("               \(category.description)\n")
      out(
        "               \(category.labels.count) daemons · ~\(category.approxMemoryMB) MB idle footprint when enabled\n"
      )
      out("               When disabled: \(category.downside)\n")
      out("\nDaemons:\n")
      for label in category.labels {
        let description = category.serviceDescriptions[label] ?? ""
        out(description.isEmpty ? "  \(label)\n" : "  \(padRight(label, 44)) \(description)\n")
      }
      for service in category.alwaysEnabled {
        out("  \(padRight(service.label, 44)) Always on — \(service.reason)\n")
      }
      return 0
    }

    if json {
      out(try jsonText(Catalog.categories))
      return 0
    }
    for category in Catalog.categories {
      out("\(padRight(category.id, 14)) \(category.name)\n")
      out(
        "               \(category.labels.count) daemons · ~\(category.approxMemoryMB) MB idle footprint when enabled\n"
      )
      out("               When disabled: \(category.downside)\n")
      for service in category.alwaysEnabled {
        out("               Always on: \(service.label) — \(service.reason)\n")
      }
    }
    out(
      "\n\(Catalog.slimmableSet.count) daemons across \(Catalog.categories.count) categories. "
        + "Core workflow and deadlock-prone daemons are never disabled.\n")
    out(
      "Memory estimates are iOS 26.5 clean-boot measurements; they vary by runtime and workload and are not additive.\n"
    )
    return 0
  }

  func cmdStatus(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let showDropped = context.parsed.bool("dropped")
    let udid = try oneUDID(context.parsed.positionals)
    let (status, disabled) = try context.simctl.readStatus(udid: udid)
    let dropped = showDropped ? Catalog.droppedCategories(disabled: disabled) : []

    if json {
      context.stdout(
        try jsonText(StatusOutput(status: status, verdict: status.verdict, dropped: dropped)))
      return 0
    }
    let out = context.stdout
    out(
      "\(udid): \(status.managedDisabled)/\(status.managedTotal) managed launchd labels disabled (\(status.verdict))\n"
    )
    if status.managedDisabled > 0 && !status.persistent {
      out(
        "  This runtime cannot persist launchd overrides: the state reverts to stock at the next reboot.\n"
      )
    }
    if showDropped {
      if dropped.isEmpty { out("  Nothing dropped; every managed launchd label is enabled.\n") }
      for category in dropped {
        out("  \(padRight(category.id, 14)) \(category.name) — \(category.downside)\n")
        for label in category.labels { out("    \(label)\n") }
      }
    }
    return 0
  }

  func cmdVerify(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    let profile = try buildProfile(
      profilePath: context.parsed.string("profile"), except: context.parsed.string("except"),
      keep: context.parsed.string("keep"))
    let result = try context.simctl.verifyProfile(udid: udid, profile: profile)
    let out = context.stdout

    if json {
      out(try jsonText(result))
    } else if result.ok {
      out("\(udid) matches the profile: all expected disable overrides are applied.\n")
    } else {
      out(
        "\(udid) does not match the profile (\(result.missing.count) missing, \(result.extra.count) extra):\n"
      )
      for label in result.missing {
        out("  missing \(label) (should be disabled, is enabled)\n")
      }
      for label in result.extra { out("  extra   \(label) (disabled beyond the profile)\n") }
      out("Re-run `simslim on` with the same profile to repair.\n")
    }
    return result.ok ? 0 : 1
  }

  func cmdDoctor(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let out = context.stdout

    if context.parsed.bool("list") {
      guard context.parsed.positionals.isEmpty else {
        throw SimSlimError("doctor --list takes no arguments")
      }
      if json {
        out(try jsonText(Catalog.features))
        return 0
      }
      for feature in Catalog.features {
        out(
          "\(padRight(feature.id, 16)) \(padRight(feature.name, 38)) \(feature.labels.joined(separator: ", "))\n"
        )
      }
      return 0
    }

    let udid = try oneUDID(context.parsed.positionals)
    let features = try Catalog.resolveFeatures(splitList(context.parsed.string("requires")))
    guard !features.isEmpty else {
      throw SimSlimError(
        "doctor needs at least one feature via --requires (see `simslim doctor --list`)")
    }

    let (_, disabled) = try context.simctl.readStatus(udid: udid)
    var report = Catalog.diagnoseFeatures(features, disabled: disabled)
    report.udid = udid

    if json {
      out(try jsonText(report))
    } else {
      let broken = report.features.filter { !$0.ok }.count
      out(
        "\(udid): \(report.features.count - broken)/\(report.features.count) required features OK\n"
      )
      for feature in report.features {
        if feature.ok {
          out("  ok    \(feature.id)\n")
        } else {
          out("  BROKEN \(feature.id) — \(feature.disabled.joined(separator: ", ")) disabled\n")
        }
      }
    }
    return report.ok ? 0 : 1
  }

  func cmdMeasure(_ context: Context) throws -> Int32 {
    let udid = try oneUDID(context.parsed.positionals)
    let measurement = try context.simctl.measure(udid: udid)
    if context.parsed.bool("json") {
      context.stdout(try jsonText(measurement))
    } else {
      context.stdout(
        "\(udid): \(measurement.processes) processes, \(humanBytes(measurement.bytes)) memory footprint (phys_footprint)\n"
      )
    }
    return 0
  }
}
