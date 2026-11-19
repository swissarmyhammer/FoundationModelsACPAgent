import Foundation
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The agent owns one transcript search index (D207 (b), Q66) over the `server` folder of the
/// session search in the local root of its home. The Mac app makes a second index over the
/// `client` folder.
@Suite struct TranscriptSearchWiringTests {
  /// The prefix that names the throwaway folders of each test.
  private static let label = "TranscriptSearchWiringTests"

  /// The server folder of the session search is `session-search/server` in the local root.
  @Test func theServerFolderIsInTheSessionSearchFolderOfTheLocalRoot() {
    let home = AgentHomeFixture.make(label: "\(Self.label)-server")

    #expect(
      home.serverSessionSearchDirectory
        == home.local.appendingPathComponent("session-search/server", isDirectory: true))
  }

  /// The client folder of the session search is `session-search/client` in the local root.
  @Test func theClientFolderIsInTheSessionSearchFolderOfTheLocalRoot() {
    let home = AgentHomeFixture.make(label: "\(Self.label)-client")

    #expect(
      home.clientSessionSearchDirectory
        == home.local.appendingPathComponent("session-search/client", isDirectory: true))
  }

  /// The index of the agent uses the server folder of its home.
  @Test func theIndexOfTheAgentUsesTheServerFolder() async throws {
    let home = AgentHomeFixture.make(label: "\(Self.label)-agent")
    let composed = try await composeStubAgent(
      name: Self.label, label: "\(Self.label)-agent", home: home)

    #expect(composed.agent.transcriptSearchIndex.folder == home.serverSessionSearchDirectory)
  }

  /// The index of the agent embeds with the `embedding` slot of the resident profile, and names
  /// the model of that slot.
  @Test func theIndexOfTheAgentNamesTheEmbeddingModelOfTheProfile() async throws {
    let composed = try await composeStubAgent(
      name: Self.label, label: "\(Self.label)-model")

    #expect(
      composed.agent.transcriptSearchIndex.modelID
        == composed.agent.residentProfile.embedding.chosen.stringValue)
  }
}
