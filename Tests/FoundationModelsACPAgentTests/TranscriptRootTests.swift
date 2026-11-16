import Foundation
import FoundationModelsACPAgent
import Testing

/// The recording root of a project (D187): `<cwd>/.<name>/transcripts/`.
/// No setting moves it.
@Suite struct TranscriptRootTests {
  /// The dotfolder name of the suite.
  static let agentName = "testagent"

  /// A working directory that never exists; the root is pure path math.
  static let workingDirectory = URL(fileURLWithPath: "/Users/dev/example", isDirectory: true)

  /// The recording root is `<cwd>/.<name>/transcripts/`.
  @Test func theRootIsInTheProject() throws {
    let root = TranscriptRoot.recordingRoot(
      workingDirectory: Self.workingDirectory, name: try DotfolderName(Self.agentName))

    #expect(root.path == "/Users/dev/example/.testagent/transcripts")
  }
}
