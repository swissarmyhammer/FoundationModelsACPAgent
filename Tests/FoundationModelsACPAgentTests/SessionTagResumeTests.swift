import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsKanban
import Testing

@testable import FoundationModelsACPAgent
@testable import acp_agent

/// A resumed session gets the tag, and so the actor, that it had before
/// (`SessionTagStore`): `undoChange(input: {})` after a resume reaches the
/// changes that the same session made before the resume.
@Suite struct SessionTagResumeTests {
  /// A write of the actor of a session, a resume of that session, and an
  /// `undoChange(input: {})` in the resumed session reverses the write.
  @Test
  func anUndoAfterAResumeReversesTheWriteFromBeforeTheResume() async throws {
    var resume = try await ResumeSessionFixture.make(label: "SessionTagResumeTests-undo")
    let harness = resume.fixture.harness
    let sessionId = resume.fixture.sessionId
    let root = try resume.recordingRoot
    _ = try await resume.runPrompt("one prompt before the resume")
    try await ResumeSessionFixture.waitForRecordedResponses(
      under: root, sessionId: sessionId, count: 1, agent: harness.agent)
    let recordedTag = SessionTagStore.tag(of: sessionId, in: root)
    let context = SessionToolContext(
      workingDirectory: resume.fixture.cwd, agentName: AgentClientHarness.dotfolderName,
      sessionTag: recordedTag)
    let before = try await KanbanHost.shared.session(
      workingDirectory: context.workingDirectory, actor: context.actorName)
    _ = try await before.execute(
      query: "mutation { addTask(input: { title: \"before the resume\" }) { title } }",
      variables: [:], operationName: nil, viewer: nil)
    _ = try await harness.connection.closeSession(CloseSessionRequest(sessionId: sessionId))
    await harness.agent.registerSessionToolFactories([AgentComposition.kanbanToolFactory])

    _ = try await harness.connection.resumeSession(resume.makeResumeRequest())

    let endpoints = await harness.agent.sessions[sessionId]?.surface.graphQLEndpoints ?? []
    let endpoint = try #require(endpoints.first { $0.name == "kanban" })
    let undone = try await endpoint.execute(
      query: "mutation { undoChange(input: {}) { txn } }",
      variables: [:], operationName: nil, viewer: nil)
    #expect(!undone.contains("\"errors\""), "the undo found no change of its actor")
    let history = try await endpoint.execute(
      query: "{ board { history { ops undone } } }",
      variables: [:], operationName: nil, viewer: nil)
    #expect(try Self.isUndone(operation: "addTask", in: history))
    await resume.fixture.close()
  }

  /// Whether the history holds a change of `operation` that a later undo reversed.
  ///
  /// - Parameters:
  ///   - operation: The name of the mutation.
  ///   - history: The JSON text of the response of the history query.
  /// - Returns: `true` when such a change is marked undone.
  /// - Throws: The JSON error.
  private static func isUndone(operation: String, in history: String) throws -> Bool {
    let root = try JSONSerialization.jsonObject(with: Data(history.utf8)) as? [String: Any]
    let board = (root?["data"] as? [String: Any])?["board"] as? [String: Any]
    let changes = board?["history"] as? [[String: Any]] ?? []
    return changes.contains { change in
      (change["ops"] as? [String])?.contains(operation) == true && change["undone"] as? Bool == true
    }
  }
}
