// Copyright (c) 2026 Pavel Akhrameev (Swift port). MIT License; see LICENSE.

import Foundation

/// How a booted simulator's launchd disable overrides compare to a profile's
/// desired set. Only managed labels are considered.
public struct VerifyResult: Codable, Equatable, Sendable {
  public var udid: String
  public var ok: Bool
  public var missing: [String]  // the profile wants these disabled; they are enabled
  public var extra: [String]  // managed labels disabled beyond the profile

  public init(udid: String = "", ok: Bool, missing: [String], extra: [String]) {
    self.udid = udid
    self.ok = ok
    self.missing = missing
    self.extra = extra
  }

  private enum CodingKeys: String, CodingKey { case udid, ok, missing, extra }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(udid, forKey: .udid)
    try c.encode(ok, forKey: .ok)
    if !missing.isEmpty { try c.encode(missing, forKey: .missing) }  // Go omitempty
    if !extra.isEmpty { try c.encode(extra, forKey: .extra) }
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    udid = try c.decode(String.self, forKey: .udid)
    ok = try c.decode(Bool.self, forKey: .ok)
    missing = try c.decodeIfPresent([String].self, forKey: .missing) ?? []
    extra = try c.decodeIfPresent([String].self, forKey: .extra) ?? []
  }
}

/// Diffs the currently disabled labels against the desired set, restricted to
/// the managed universe: unmanaged labels are never simslim's business and
/// never count as drift.
public func compareDisabled(
  disabled: Set<String>, desired: Set<String>, managed: Set<String>
) -> VerifyResult {
  let missing = desired.filter { !disabled.contains($0) }.sorted()
  let extra = disabled.filter { managed.contains($0) && !desired.contains($0) }.sorted()
  return VerifyResult(ok: missing.isEmpty && extra.isEmpty, missing: missing, extra: extra)
}

extension Simctl {
  /// Checks, without mutating anything, that a booted simulator's disable
  /// overrides match the profile exactly. The overrides are per-simulator state
  /// that is easy to lose silently when a device is erased or recreated.
  public func verifyProfile(udid: String, profile: Profile) throws -> VerifyResult {
    let device = try findDevice(udid: udid)
    guard device.state == "Booted" else {
      throw SimSlimError("simulator must be booted to read its state (it is \(device.state))")
    }
    let disabled = try readDisabled(set: device.set, udid: device.udid)
    var result = compareDisabled(
      disabled: disabled, desired: profile.desired(for: device), managed: Catalog.managedSet)
    result.udid = udid
    return result
  }
}
