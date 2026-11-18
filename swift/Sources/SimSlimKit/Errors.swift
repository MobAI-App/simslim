import Foundation

/// An error whose message is meant to be shown to the user as-is.
public struct SimSlimError: Error, LocalizedError, CustomStringConvertible, Equatable {
  public let message: String

  public init(_ message: String) { self.message = message }

  public var description: String { message }
  public var errorDescription: String? { message }
}
