import Foundation

/// The one writer of a named text file in a test tree. The fixtures that write a file with a fixed
/// name (`AgentsFileFixture`, `ConfigFileFixture`, `AgentFolderFixture`) call it, so each file is
/// written the same way, and the nested `IntegrationTests` package reaches it as a product.
public enum TestFileFixture {
  /// Writes `text` as the file `fileName` inside `directory`, and creates the directory first.
  /// A second write replaces the text of the file.
  ///
  /// - Parameters:
  ///   - text: The file content.
  ///   - fileName: The name of the file.
  ///   - directory: The folder the file goes in.
  /// - Throws: The directory-creation or write error.
  public static func write(_ text: String, named fileName: String, in directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try text.write(
      to: directory.appendingPathComponent(fileName, isDirectory: false),
      atomically: true, encoding: .utf8)
  }
}
