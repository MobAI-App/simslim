import Foundation
import SimSlimKit

extension CLI {
  private func bounded(_ simctl: Simctl, by seconds: TimeInterval) -> Simctl {
    var copy = simctl
    copy.deadline = copy.now().addingTimeInterval(seconds)
    return copy
  }

  func cmdSize(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    let bytes = try bounded(context.simctl, by: context.bootTimeout).deviceDiskUsage(udid: udid)
    if json {
      context.stdout(try jsonText(DiskMeasurement(bytes: bytes)))
    } else {
      context.stdout("\(udid): \(humanBytes(bytes)) on disk\n")
    }
    return 0
  }

  func cmdDiskCategories(_ context: Context) throws -> Int32 {
    guard context.parsed.positionals.isEmpty else {
      throw SimSlimError("disk-categories takes no arguments")
    }
    if context.parsed.bool("json") {
      context.stdout(try jsonText(diskCleanupCategories))
      return 0
    }
    for category in diskCleanupCategories {
      let availability = category.canClean ? "cleanable" : "measured only"
      context.stdout(
        "\(padRight(category.id, 22)) \(padRight(category.name, 28)) \(category.risk) · \(availability)\n"
      )
      context.stdout("                       \(category.downside)\n")
    }
    return 0
  }

  func cmdDiskPlan(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    let plan = try bounded(context.simctl, by: context.bootTimeout).planDiskCleanup(udid: udid)
    if json {
      context.stdout(try jsonText(plan))
      return 0
    }
    context.stdout("\(udid): \(humanBytes(plan.cleanableBytes)) currently cleanable\n")
    for measurement in plan.categories {
      let note = measurement.category.canClean ? "" : " (iOS-managed; measured only)"
      context.stdout(
        "  \(padRight(measurement.category.id, 22)) \(padLeft(humanBytes(measurement.bytes), 8))\(note)\n"
      )
    }
    if !plan.storage.isEmpty {
      context.stdout("  Stored data (read only)\n")
      for storage in plan.storage {
        context.stdout(
          "    \(padRight(storage.id, 20)) \(padLeft(humanBytes(storage.bytes), 8))\n")
      }
    }
    return 0
  }

  func cmdDiskClean(_ context: Context) throws -> Int32 {
    let json = context.parsed.bool("json")
    let udid = try oneUDID(context.parsed.positionals)
    guard context.parsed.bool("confirm") else {
      throw SimSlimError(
        "disk-clean permanently deletes data; pass --confirm after reviewing `simslim disk-plan \(udid)`"
      )
    }
    let categoryIDs = splitList(context.parsed.string("categories"))
    _ = try validateDiskCleanupSelection(categoryIDs)
    let result = try bounded(context.simctl, by: context.bootTimeout).cleanDeviceDisk(
      udid: udid, categoryIDs: categoryIDs,
      preserveBootState: context.parsed.bool("preserve-boot-state"))
    if json {
      context.stdout(try jsonText(result))
    } else {
      context.stdout(
        "Cleaned \(udid) and reclaimed \(humanBytes(result.reclaimedBytes)). Generated contents stay deleted; on-demand assets may download again when needed.\n"
      )
    }
    return 0
  }
}
