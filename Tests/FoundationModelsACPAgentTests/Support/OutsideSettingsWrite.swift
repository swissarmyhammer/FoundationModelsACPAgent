import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

/// An outside write of a settings file while a change stream watches it, for
/// the suites of ``SettingsStore`` and of the `settings` endpoint.
///
/// Each suite gives its own way to open the change stream and to read one
/// change: the `changes()` stream of the store, or the `changes`
/// subscription of the endpoint.
enum OutsideSettingsWrite {
  /// Writes `firstText` to the `config.yaml` in `root`, opens the change
  /// stream, writes `text` to the file from outside, and reads the change of
  /// that write.
  ///
  /// - Parameters:
  ///   - text: The text that the outside write puts in the file.
  ///   - firstText: The text of the file before the change stream opens.
  ///   - root: The folder of the level that holds the file.
  ///   - expected: The change that the outside write must send.
  ///   - sourceLocation: The place of the call, for the expectation.
  ///   - openChanges: Opens the change stream after the first write. It
  ///     must start the watch of the level, for example with a read of the
  ///     level.
  ///   - nextChange: Reads the next change of the stream.
  /// - Returns: The iterator of the change stream after the change of the
  ///   outside write.
  /// - Throws: What the writes, `openChanges` and `nextChange` throw.
  static func write<Changes: AsyncIteratorProtocol, Change: Equatable>(
    _ text: String, over firstText: String, in root: URL, expecting expected: Change,
    sourceLocation: SourceLocation = #_sourceLocation,
    openChanges: () async throws -> Changes,
    nextChange: (inout Changes) async throws -> Change?
  ) async throws -> Changes {
    try ConfigFileFixture.write(firstText, in: root)
    var changes = try await openChanges()
    try ConfigFileFixture.write(text, in: root)
    #expect(try await nextChange(&changes) == expected, sourceLocation: sourceLocation)
    return changes
  }
}
