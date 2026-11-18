// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// A user-facing capability backed by specific launchd daemons. Every label
/// must also be managed by a Category (enforced in the tests), including
/// required services that earlier versions could have turned off.
public struct Feature: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let labels: [String]

  public init(id: String, name: String, labels: [String]) {
    self.id = id
    self.name = name
    self.labels = labels
  }
}

/// One feature's verdict: the daemons it needs that are down.
public struct FeatureStatus: Codable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let ok: Bool
  public let disabled: [String]

  public init(id: String, name: String, ok: Bool, disabled: [String]) {
    self.id = id
    self.name = name
    self.ok = ok
    self.disabled = disabled
  }

  private enum CodingKeys: String, CodingKey { case id, name, ok, disabled }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encode(name, forKey: .name)
    try c.encode(ok, forKey: .ok)
    if !disabled.isEmpty { try c.encode(disabled, forKey: .disabled) }  // Go omitempty
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    name = try c.decode(String.self, forKey: .name)
    ok = try c.decode(Bool.self, forKey: .ok)
    disabled = try c.decodeIfPresent([String].self, forKey: .disabled) ?? []
  }
}

/// Whether each required feature survives the device's current slimming. `ok`
/// is false when any required feature has a disabled daemon.
public struct DoctorOutput: Codable, Equatable, Sendable {
  public var udid: String
  public var ok: Bool
  public var features: [FeatureStatus]

  public init(udid: String = "", ok: Bool, features: [FeatureStatus]) {
    self.udid = udid
    self.ok = ok
    self.features = features
  }

  private enum CodingKeys: String, CodingKey { case udid, ok, features }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if !udid.isEmpty { try c.encode(udid, forKey: .udid) }  // Go omitempty
    try c.encode(ok, forKey: .ok)
    try c.encode(features, forKey: .features)
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    udid = try c.decodeIfPresent(String.self, forKey: .udid) ?? ""
    ok = try c.decode(Bool.self, forKey: .ok)
    features = try c.decode([FeatureStatus].self, forKey: .features)
  }
}

extension Catalog {
  /// Commonly required capabilities mapped to the daemons they need running.
  public static let features: [Feature] = featureList

  public static func feature(id: String) -> Feature? {
    features.first { $0.id == id }
  }

  /// Maps requested IDs to their Features, failing on the first unknown one so
  /// a typo in `--requires` fails loudly instead of passing silently.
  public static func resolveFeatures(_ ids: [String]) throws -> [Feature] {
    try ids.map { id in
      guard let feature = feature(id: id) else {
        throw SimSlimError("unknown feature \"\(id)\" (see `simslim doctor --list`)")
      }
      return feature
    }
  }

  /// Reports, for each feature, which of its daemons the device currently has
  /// disabled. A feature is OK only when none of them are.
  public static func diagnoseFeatures(_ features: [Feature], disabled: Set<String>) -> DoctorOutput
  {
    var allOK = true
    var statuses: [FeatureStatus] = []
    for feature in features {
      let down = feature.labels.filter { disabled.contains($0) }
      let ok = down.isEmpty
      allOK = allOK && ok
      statuses.append(FeatureStatus(id: feature.id, name: feature.name, ok: ok, disabled: down))
    }
    return DoctorOutput(ok: allOK, features: statuses)
  }
}
