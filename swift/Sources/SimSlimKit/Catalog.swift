// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// Shown alongside a category for transparency but never part of a slim
/// profile. Earlier versions may have disabled it, so it stays in the mutation
/// allowlist solely to repair that legacy state.
public struct AlwaysEnabledService: Codable, Equatable, Sendable {
  public let label: String
  public let reason: String

  public init(label: String, reason: String) {
    self.label = label
    self.reason = reason
  }
}

/// Raw, generated category data (see Generated/CatalogData.swift).
struct CategorySeed {
  let id: String
  let name: String
  let description: String
  let downside: String
  let approxMemoryMB: Int
  let labels: [String]
  let alwaysEnabled: [AlwaysEnabledService]
}

/// Groups launchd daemon labels that a slim boot disables together.
///
/// The JSON shape is a contract with the SwiftUI app (`gui/Models.swift`).
public struct Category: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let description: String
  public let downside: String
  public let approxMemoryMB: Int
  public let labels: [String]
  public let serviceDescriptions: [String: String]
  public let alwaysEnabled: [AlwaysEnabledService]

  init(seed: CategorySeed) {
    id = seed.id
    name = seed.name
    description = seed.description
    downside = seed.downside
    approxMemoryMB = seed.approxMemoryMB
    labels = seed.labels
    // A label without a description maps to "", exactly like the Go map
    // lookup; the tests reject any such label.
    serviceDescriptions = Dictionary(
      uniqueKeysWithValues: seed.labels.map { ($0, serviceDescriptionByLabel[$0] ?? "") }
    )
    alwaysEnabled = seed.alwaysEnabled
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, description, downside, approxMemoryMB, labels, serviceDescriptions, alwaysEnabled
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(description, forKey: .description)
    try c.encode(downside, forKey: .downside)
    try c.encode(approxMemoryMB, forKey: .approxMemoryMB)
    try c.encode(labels, forKey: .labels)
    try c.encode(serviceDescriptions, forKey: .serviceDescriptions)
    // Go's `omitempty`: absent when there are none.
    if !alwaysEnabled.isEmpty { try c.encode(alwaysEnabled, forKey: .alwaysEnabled) }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    description = try c.decode(String.self, forKey: .description)
    downside = try c.decode(String.self, forKey: .downside)
    approxMemoryMB = try c.decode(Int.self, forKey: .approxMemoryMB)
    labels = try c.decode([String].self, forKey: .labels)
    serviceDescriptions = try c.decode([String: String].self, forKey: .serviceDescriptions)
    alwaysEnabled = try c.decodeIfPresent([AlwaysEnabledService].self, forKey: .alwaysEnabled) ?? []
  }
}

/// The complete allowlist of daemons a profile may disable.
///
/// Categories may overlap: a label lives in every category whose feature needs
/// it, and an excepted category keeps all its labels enabled even when a
/// slimmed category also lists them. `approxMemoryMB` values are rounded median
/// increases in phys_footprint, not additive.
public enum Catalog {
  public static let categories: [Category] = categorySeeds.map(Category.init(seed:))

  public static func category(id: String) -> Category? {
    categories.first { $0.id == id }
  }

  /// Every label a service profile may disable.
  public static let slimmableSet: Set<String> = Set(categories.flatMap(\.labels))

  /// The complete mutation allowlist. Most labels are slimmable; required
  /// labels may only transition back to enabled, for compatibility.
  public static let managedSet: Set<String> =
    slimmableSet.union(categories.flatMap(\.alwaysEnabled).map(\.label))
}
