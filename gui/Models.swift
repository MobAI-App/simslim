import Foundation

enum SlimmingMode: String, CaseIterable, Identifiable {
  case memory = "Memory Use"
  case disk = "Disk Size"

  var id: String { rawValue }
}

struct SimulatorDevice: Decodable, Identifiable, Equatable {
  let udid: String
  let name: String
  let state: String
  let osVersion: String
  let managedDisabled: Int?
  let managedTotal: Int
  let statusError: String?
  let memory: SimulatorMeasurement?
  let memoryError: String?

  var id: String { udid }
  var isBooted: Bool { state == "Booted" }
}

struct SlimCategory: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let downside: String
  let approxMemoryMB: Int
  let labels: [String]
  let serviceDescriptions: [String: String]?
  let alwaysEnabled: [AlwaysEnabledService]?

  var alwaysEnabledServices: [AlwaysEnabledService] {
    alwaysEnabled ?? []
  }

  var approximateMemoryText: String {
    "Uses ~\(approxMemoryMB) MB RAM"
  }

  func serviceDescription(for label: String) -> String {
    serviceDescriptions?[label] ?? "Apple background service."
  }
}

struct AlwaysEnabledService: Decodable, Identifiable, Equatable {
  let label: String
  let reason: String

  var id: String { label }
}

struct SimulatorMeasurement: Decodable, Equatable {
  let processes: Int
  let bytes: Int64

  var memoryText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
  }
}

struct SimulatorDiskMeasurement: Decodable, Equatable {
  let bytes: Int64

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct DiskCleanupCategory: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let downside: String
  let recovery: String
  let risk: String
  let defaultSelected: Bool
  let canClean: Bool
}

struct SimulatorDiskCleanupMeasurement: Decodable, Equatable {
  let id: String
  let bytes: Int64
  let targets: Int

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

struct SimulatorDiskStorageMeasurement: Decodable, Identifiable, Equatable {
  let id: String
  let name: String
  let description: String
  let bytes: Int64

  var sizeText: String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  var systemImage: String {
    switch id {
    case "installed-apps": return "app.dashed"
    case "documents": return "doc"
    case "app-data": return "externaldrive"
    case "user-media": return "photo.on.rectangle"
    default: return "folder"
    }
  }
}

struct SimulatorDiskCleanupPlan: Decodable, Equatable {
  let udid: String
  let totalBytes: Int64
  let cleanableBytes: Int64
  let categories: [SimulatorDiskCleanupMeasurement]
  let storage: [SimulatorDiskStorageMeasurement]

  func bytes(for categoryID: String) -> Int64 {
    categories.first(where: { $0.id == categoryID })?.bytes ?? 0
  }

  func storageBytes(for storageID: String) -> Int64 {
    storage.first(where: { $0.id == storageID })?.bytes ?? 0
  }
}

struct SimulatorDiskCleanupResult: Decodable, Equatable {
  let udid: String
  let categoryIds: [String]
  let beforeBytes: Int64
  let afterBytes: Int64
  let reclaimedBytes: Int64
  let wasBooted: Bool
  let bootStateRestored: Bool

  var reclaimedText: String {
    ByteCountFormatter.string(fromByteCount: reclaimedBytes, countStyle: .file)
  }
}

struct SimulatorMutationResult: Decodable, Equatable {
  let action: String
  let udid: String
  let name: String?
  let sourceUdid: String?
}

enum ServiceSlimState: Equatable {
  case stock
  case partial(disabled: Int, total: Int)
  case full(total: Int)
  case unknown

  var title: String {
    switch self {
    case .stock: return "Stock"
    case .partial(let disabled, let total): return "Partial (\(disabled)/\(total))"
    case .full(let total): return "Fully slim (\(total)/\(total))"
    case .unknown: return "Unknown while shutdown"
    }
  }

  var systemImage: String {
    switch self {
    case .stock: return "circle.fill"
    case .partial: return "circle.lefthalf.filled"
    case .full: return "circle"
    case .unknown: return "questionmark.circle"
    }
  }
}

struct BatchProgress: Equatable {
  let completed: Int
  let total: Int
  let currentName: String
  let action: String

  var fraction: Double {
    guard total > 0 else { return 0 }
    return Double(completed) / Double(total)
  }
}

struct ActivityEntry: Identifiable, Equatable {
  enum Level {
    case info
    case success
    case failure
  }

  let id = UUID()
  let date = Date()
  let level: Level
  let message: String
}

struct PresentedError: Identifiable {
  let id = UUID()
  let message: String
}
