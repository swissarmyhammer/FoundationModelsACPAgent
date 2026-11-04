import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsRouter
import MetricsTestKit
import TelemetryTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// A nested session is an ordinary session with a parent. It has the same
/// build as a root session, with one parent link more. One chain of three
/// sessions (a root, a child and a grandchild) follows the same rule at
/// each link.
@Suite(.closesHarnesses) struct SessionSetupNestedTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SessionSetupNestedTests"

  /// The name of an endpoint that no session has.
  private static let missingEndpointName = "no-such-endpoint"

  /// The value of the `active_sessions` gauge when one session is open.
  private static let oneOpenSession = 1.0

  /// The text of the prompt that the root session answers after a retire.
  private static let promptText = "Say hello."

  /// The answer of the scripted model.
  private static let answerText = "hello"

  /// Makes a Router session that stands for the session of a sub-agent
  /// run, below `parentSession`.
  ///
  /// - Parameter parentSession: The Router session of the parent.
  /// - Returns: The new session.
  static func makeNestedRouterSession(below parentSession: any RoutedSession) -> any RoutedSession {
    parentSession.profile.standard.makeSession(
      workingDirectory: parentSession.workingDirectory,
      recordingRoot: parentSession.recordingDirectory.deletingLastPathComponent(),
      agentSpawn: SessionRecord.AgentSpawn(
        parentSessionId: parentSession.id, parentToolCallId: "tool-call-1"))
  }

  /// Opens a nested session below `parentId` on the agent of `fixture`.
  ///
  /// - Parameters:
  ///   - fixture: The fixture that holds the agent.
  ///   - parentId: The session that is the parent.
  /// - Returns: The id of the nested session.
  /// - Throws: Whatever the registration throws.
  static func openNestedSession(
    in fixture: ScriptedPromptFixture, below parentId: SessionId
  ) async throws -> SessionId {
    let agent = fixture.harness.agent
    let parentSession = try #require(await agent.sessions[parentId]?.session)
    let nested = makeNestedRouterSession(below: parentSession)
    return try await agent.registerNestedSession(nested, parent: parentId)
  }

  /// One message chunk, as a session sends it.
  ///
  /// - Returns: The update.
  static func makeMessageUpdate() -> SessionUpdate {
    .agentMessageChunk(
      ContentChunk(
        content: .text(TextContent(text: answerText)), messageId: ACPEventTranslator.makeMessageId()
      ))
  }

  /// Whether a notification holds a message chunk of `sessionId`.
  ///
  /// - Parameters:
  ///   - notification: The notification.
  ///   - sessionId: The session.
  /// - Returns: `true` for a message chunk of that session.
  private static func isMessage(_ notification: UpdateSessionNotification, of sessionId: SessionId)
    -> Bool
  {
    guard notification.sessionId == sessionId, case .agentMessageChunk = notification.update else {
      return false
    }
    return true
  }

  // MARK: The entry

  /// The entry of a nested session is in the table of the agent, with its
  /// parent link. The parent entry names it as a child.
  @Test
  func theNestedSessionHasAnEntryWithItsParentLink() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent

    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    let entry = try #require(await agent.sessions[childId])
    #expect(entry.parentSessionId == fixture.sessionId)
    #expect(await agent.sessions[fixture.sessionId]?.children == [childId])
    #expect(agent.sessionTree.ancestors(of: childId) == [fixture.sessionId])
    await fixture.close()
  }

  /// The ACP id of a nested session is the ULID of its Router session, as
  /// for a root session.
  @Test
  func theNestedSessionIdIsTheRouterUlid() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)

    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    let entry = try #require(await fixture.harness.agent.sessions[childId])
    #expect(entry.session.id.description == childId.rawValue)
    await fixture.close()
  }

  /// The nested session owns its ledger, projector and retained history:
  /// none of them is the one of its parent.
  @Test
  func theNestedSessionOwnsItsLedgerProjectorAndHistory() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let parent = try #require(await agent.sessions[fixture.sessionId])

    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    let child = try #require(await agent.sessions[childId])
    #expect(child.stateLedger !== parent.stateLedger)
    #expect(child.projector !== parent.projector)
    #expect(child.retainedHistory !== parent.retainedHistory)
    await fixture.close()
  }

  /// The nested session borrows the command registry of its parent. It
  /// owns the join table of its projector. Thus the stop of its projector
  /// cannot seal the runs that the parent waits for.
  @Test
  func theNestedSessionBorrowsTheCommandsAndOwnsItsJoinTable() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let parent = try #require(await agent.sessions[fixture.sessionId])

    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    let child = try #require(await agent.sessions[childId])
    #expect(child.commands === parent.commands)
    #expect(child.projector.runCallJoins !== parent.projector.runCallJoins)
    await fixture.close()
  }

  /// A grandchild below the child has both as ancestors, root first, and
  /// the parent of the child names it.
  @Test
  func aGrandchildHasTheRootAndTheChildAsAncestors() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    let grandchildId = try await Self.openNestedSession(in: fixture, below: childId)

    #expect(
      fixture.harness.agent.sessionTree.ancestors(of: grandchildId) == [fixture.sessionId, childId])
    await fixture.close()
  }

  /// A nested session below a session that the table does not hold is
  /// refused, and it leaves no link.
  @Test
  func aNestedSessionBelowAnUnknownParentIsRefused() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let parentSession = try #require(await agent.sessions[fixture.sessionId]?.session)
    let nested = Self.makeNestedRouterSession(below: parentSession)
    let unknown = SessionId(rawValue: ULID().ulidString)

    await #expect(throws: RequestError.unknownSession(id: unknown)) {
      try await agent.registerNestedSession(nested, parent: unknown)
    }
    #expect(agent.sessionTree.parent(of: SessionId(rawValue: nested.id.description)) == nil)
    await fixture.close()
  }

  // MARK: The updates

  /// A child has no owner of its own. It takes the connection of its
  /// parent. So an update of the child goes out there, under the id of the
  /// child.
  @Test
  func anUpdateOfTheNestedSessionReachesTheConnectionOfItsParent() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)
    let child = try #require(await agent.sessions[childId])
    await child.announcement.open()

    await child.projector.commandSink(Self.makeMessageUpdate())

    _ = try await fixture.collector.wait(for: "the message of the child") { updates in
      updates.contains { Self.isMessage($0, of: childId) }
    }
    await fixture.close()
  }

  /// Until the announcement opens the gate, no update of the nested
  /// session leaves the agent. The retained history of the nested
  /// session keeps it.
  @Test
  func noUpdateOfTheNestedSessionLeavesBeforeTheAnnouncement() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)
    let child = try #require(await agent.sessions[childId])

    // A send to a closed gate waits for its own send, so the update runs in a task.
    let kept = Task { await child.projector.commandSink(Self.makeMessageUpdate()) }
    while child.announcement.pendingCount == 0 {
      await Task.yield()
    }

    let sent = await fixture.collector.updates.contains { $0.sessionId == childId }
    #expect(!sent)
    #expect(!child.history.entries.isEmpty)
    child.announcement.discard()
    await kept.value
    await fixture.close()
  }

  // MARK: The tables that read the sessions

  /// The `active_sessions` gauge counts the sessions that a client opened.
  /// A nested session is one more entry of the table. It is not one more
  /// open session.
  @Test
  func theActiveSessionsGaugeDoesNotCountANestedSession() async throws {
    let lastValue = try await TelemetryCapture.run(forbidding: []) { context in
      let fixture = try await ScriptedPromptFixture.make(
        script: [.endPass], label: Self.label, tracer: context.tracer)
      _ = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)
      let gauge = try context.metricsFactory.expectGauge(
        ACPAgentTelemetry.MetricName.activeSessions)
      let lastValue = gauge.lastValue
      await fixture.close()
      return lastValue
    }

    #expect(lastValue == Self.oneOpenSession)
  }

  /// The tunnel reaches a session through its own endpoints. A nested
  /// session has none. It borrows the tools of its parent. So a call that
  /// names it gets `NOT_FOUND`. This is the same answer as for a session
  /// that the agent does not have.
  @Test
  func theTunnelDoesNotAnswerForANestedSession() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    await #expect(throws: GraphQLTunnelError.sessionNotFound(childId)) {
      try await agent.tunnelEndpoint(
        named: Self.missingEndpointName, sessionId: childId,
        viewer: agent.connections.viewer(of: .direct))
    }
    await fixture.close()
  }

  // MARK: The end

  /// Retiring a nested session removes its entry and its link. The
  /// parent goes on. Its surface is not shut down. So a prompt of the
  /// parent still ends.
  @Test
  func retiringTheNestedSessionLeavesTheParentWorking() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.textDelta(Self.answerText), .endPass], label: Self.label)
    let agent = fixture.harness.agent
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    await agent.retireSession(childId)

    #expect(await agent.sessions[childId] == nil)
    #expect(agent.sessionTree.children(of: fixture.sessionId).isEmpty)
    #expect(await agent.sessions[fixture.sessionId]?.children.isEmpty == true)
    _ = try await fixture.harness.connection.prompt(
      AgentClientHarness.makePromptRequest(sessionId: fixture.sessionId, text: Self.promptText))
    _ = try await ScriptedPromptFixture.waitForIdle(fixture.collector)
    #expect(ScriptedPromptFixture.agentText(in: await fixture.collector.updates) == Self.answerText)
    await fixture.close()
  }

  /// Retiring the nested session releases its owner: it has no outbound
  /// path after.
  @Test
  func retiringTheNestedSessionReleasesItsOwner() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)

    await agent.retireSession(childId)

    #expect(agent.connections.path(forSession: childId) == nil)
    await fixture.close()
  }

  /// Closing the root session retires each session below it, the same rule
  /// at each level of the chain.
  @Test
  func closingTheRootRetiresTheChildAndTheGrandchild() async throws {
    let fixture = try await ScriptedPromptFixture.make(script: [.endPass], label: Self.label)
    let agent = fixture.harness.agent
    let childId = try await Self.openNestedSession(in: fixture, below: fixture.sessionId)
    let grandchildId = try await Self.openNestedSession(in: fixture, below: childId)

    _ = try await fixture.harness.connection.closeSession(
      CloseSessionRequest(sessionId: fixture.sessionId))

    #expect(await agent.sessions[childId] == nil)
    #expect(await agent.sessions[grandchildId] == nil)
    #expect(agent.sessionTree.children(of: fixture.sessionId).isEmpty)
    await fixture.close()
  }
}
