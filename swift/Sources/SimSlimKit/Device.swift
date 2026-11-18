import Foundation

/// A simulator. The JSON keys are a contract with the SwiftUI app; `dataPath`
/// and `runtimeID` are deliberately not part of it.
public struct Device: Codable, Equatable, Sendable {
  public var udid: String
  public var name: String
  public var state: String  // "Booted" or "Shutdown"
  public var platform: String  // "iOS", "tvOS", "watchOS", or "visionOS"
  public var osVersion: String
  public var set: String
  public var dataPath: String = ""
  public var runtimeID: String = ""

  public init(
    udid: String,
    name: String = "",
    state: String = "",
    platform: String = "",
    osVersion: String = "",
    set: String = "",
    dataPath: String = "",
    runtimeID: String = ""
  ) {
    self.udid = udid
    self.name = name
    self.state = state
    self.platform = platform
    self.osVersion = osVersion
    self.set = set
    self.dataPath = dataPath
    self.runtimeID = runtimeID
  }

  private enum CodingKeys: String, CodingKey {
    case udid, name, state, platform, osVersion, set
  }

  /// Preserves the iOS default for callers that build a Device without
  /// platform metadata.
  public var platformName: String { platform.isEmpty ? "iOS" : platform }

  /// The platform and version shown in human-readable output.
  public var runtimeName: String { platformName + " " + osVersion }
}
