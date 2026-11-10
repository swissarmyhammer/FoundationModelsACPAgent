import Foundation
import Testing

@testable import FoundationModelsACPAgent

/// The order of the top-level sections in the document of
/// ``ConfigurationYAML``.
///
/// The coding keys of ``AgentConfiguration`` are the one list of the
/// section names. The document emits each section in the order of that
/// list, so a new section has one place to go.
struct ConfigurationYAMLSectionOrderTests {
  /// The names of the top-level keys of `text`, in document order: each
  /// line that starts a key with no indentation.
  ///
  /// - Parameter text: The YAML document.
  /// - Returns: The top-level key names.
  private static func topLevelKeys(in text: String) -> [String] {
    text.split(separator: "\n")
      .filter { line in line.first.map { $0.isLetter } ?? false }
      .compactMap { line in line.split(separator: ":", maxSplits: 1).first.map(String.init) }
  }

  /// The document of the builtin configuration emits its sections in the
  /// order of the coding keys of ``AgentConfiguration``.
  @Test func theSectionsFollowTheOrderOfTheCodingKeys() throws {
    let text = try ConfigurationYAML.documentText(for: AgentConfiguration())

    #expect(
      Self.topLevelKeys(in: text) == AgentConfiguration.CodingKeys.allCases.map(\.stringValue))
  }
}
