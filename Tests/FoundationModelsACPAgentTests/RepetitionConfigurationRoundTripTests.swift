import Foundation
import Testing

@testable import FoundationModelsACPAgent

/// The encoder and the decoder of `RepetitionConfiguration` agree on a
/// limit that is `nil`: no limit stays no limit after a write and a read.
struct RepetitionConfigurationRoundTripTests {
  /// A configuration with no reasoning limit and no identical-call limit.
  private static var unlimited: RepetitionConfiguration {
    var configuration = RepetitionConfiguration()
    configuration.reasoningTokenLimit = nil
    configuration.identicalToolCallLimit = nil
    return configuration
  }

  /// Encodes `configuration` and decodes it again.
  ///
  /// - Parameter configuration: The configuration to write and read.
  /// - Returns: The configuration that was read.
  /// - Throws: The encode or decode error.
  private static func roundTripped(_ configuration: RepetitionConfiguration) throws
    -> RepetitionConfiguration
  {
    let data = try JSONEncoder().encode(configuration)
    return try JSONDecoder().decode(RepetitionConfiguration.self, from: data)
  }

  /// A `nil` reasoning limit is still `nil` after a round trip, and not the
  /// default limit.
  @Test func aNilReasoningLimitStaysNil() throws {
    let decoded = try Self.roundTripped(Self.unlimited)

    #expect(decoded.reasoningTokenLimit == nil)
  }

  /// A `nil` identical-call limit is still `nil` after a round trip, and
  /// not the default limit.
  @Test func aNilIdenticalToolCallLimitStaysNil() throws {
    let decoded = try Self.roundTripped(Self.unlimited)

    #expect(decoded.identicalToolCallLimit == nil)
  }

  /// A configuration with a limit set is the same after a round trip.
  @Test func aConfigurationWithLimitsIsEqualAfterARoundTrip() throws {
    let configuration = RepetitionConfiguration()

    #expect(try Self.roundTripped(configuration) == configuration)
  }
}
