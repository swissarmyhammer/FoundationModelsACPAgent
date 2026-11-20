import Foundation
import FoundationModelsExtras

/// A coded error of a GraphQL endpoint over a store.
///
/// Each conforming enum gives its own map of the known store errors in
/// ``knownCode(of:)``. The shared part gives every other error with no
/// change, and runs a store call with that map. The toolkit gives an error
/// that is not coded as `INTERNAL`.
protocol StoreCodedError: CodedError {
  /// Gives the coded error of a known store error.
  ///
  /// - Parameter error: The error that a store call threw.
  /// - Returns: The coded error of `error`, or `nil` when the map does not
  ///   know `error`.
  static func knownCode(of error: any Error) -> (any Error)?
}

extension StoreCodedError {
  /// Gives the coded error of an error of the store.
  ///
  /// - Parameter error: The error that a store call threw.
  /// - Returns: The coded error of a known store error, or `error` with no
  ///   change.
  static func coded(_ error: any Error) -> any Error {
    knownCode(of: error) ?? error
  }

  /// Runs one call of the store, and gives each error that it throws as
  /// ``coded(_:)`` gives it.
  ///
  /// - Parameter storeCall: The call of the store.
  /// - Returns: What `storeCall` returns.
  /// - Throws: The coded error of the error that `storeCall` throws.
  static func withCodedErrors<Value>(of storeCall: () async throws -> Value) async throws -> Value {
    do {
      return try await storeCall()
    } catch {
      throw coded(error)
    }
  }
}
