import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

/// The shared test-support file writer. `AgentsFileFixture`, `ConfigFileFixture` and
/// `AgentFolderFixture` write their files through it.
@Suite struct TestFileFixtureTests {
  /// The directory label of the suite.
  private static let label = "TestFileFixtureTests"

  /// The name of the file that the tests write.
  private static let fileName = "notes.txt"

  /// The text that the tests write.
  private static let text = "TEST-FILE-FIXTURE-TEXT"

  /// The writer creates a folder that does not exist, then writes the named file in it.
  @Test func writesTheNamedFileInAFolderThatDoesNotExist() throws {
    let directory = makeResolvedDirectory(label: Self.label)
      .appendingPathComponent("nested", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    try TestFileFixture.write(Self.text, named: Self.fileName, in: directory)

    let written = try String(
      contentsOf: directory.appendingPathComponent(Self.fileName, isDirectory: false),
      encoding: .utf8)
    #expect(written == Self.text)
  }
}
