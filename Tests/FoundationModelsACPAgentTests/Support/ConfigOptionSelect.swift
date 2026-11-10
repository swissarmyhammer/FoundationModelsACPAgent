import Foundation
import FoundationModelsACP
import Testing

@testable import FoundationModelsACPAgent

/// The readers of a `select` config option in a complete option state.
/// `ConfigOptionsTests` reads the `model` select and `SessionAgentTests`
/// reads the `agent` select, so the extraction lives here one time, in the
/// pattern of ``MountOrder``. Each suite keeps its own assertions on the
/// option.
enum ConfigOptionSelect {
  /// The select payload of the option with `configId` in a complete option
  /// state.
  ///
  /// - Parameters:
  ///   - options: The announced complete state.
  ///   - configId: The id of the option to read.
  /// - Returns: The select payload.
  /// - Throws: When the state has no option with `configId`, or when that
  ///   option is not a select.
  static func select(
    in options: [SessionConfigOption]?,
    configId: SessionConfigId
  ) throws -> SessionConfigSelect {
    let option = try #require(options?.first { $0.configId == configId })
    guard case .select(let select) = option.type else {
      Issue.record("expected a select option, got \(option.type)")
      throw RequestError.invalidParams
    }
    return select
  }

  /// The typed select values behind a select's raw `options` JSON, so
  /// the assertion pins the wire shape to the generated decoder.
  ///
  /// - Parameter select: The select payload.
  /// - Returns: The decoded values, in announcement order.
  /// - Throws: When the raw JSON does not decode as the flat list.
  static func decodedOptions(
    of select: SessionConfigSelect
  ) throws -> [SessionConfigSelectOption] {
    let data = try JSONEncoder().encode(select.options)
    return try JSONDecoder().decode([SessionConfigSelectOption].self, from: data)
  }
}
