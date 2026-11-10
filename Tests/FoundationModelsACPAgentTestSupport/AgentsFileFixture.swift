import Foundation
import FoundationModelsACPAgent

/// The one writer of an `AGENTS.md` file in a test tree. Each suite that puts an `AGENTS.md` in a
/// working folder calls it, so the file is written the same way in each suite, and the nested
/// `IntegrationTests` package reaches it as a product.
public enum AgentsFileFixture {
  /// Writes `text` as the `AGENTS.md` file inside `directory`, and creates the directory first.
  /// A second write replaces the text of the file.
  ///
  /// - Parameters:
  ///   - text: The file content.
  ///   - directory: The folder the file goes in.
  /// - Throws: The directory-creation or write error.
  public static func write(_ text: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try text.write(
      to: directory.appendingPathComponent(InstructionsAssembler.agentsFileName, isDirectory: false),
      atomically: true, encoding: .utf8)
  }
}
