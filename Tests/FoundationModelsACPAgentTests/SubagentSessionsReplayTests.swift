import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// A `session/resume` with `replayFrom: start` replays the nested tree of the root. The first
/// agent records a chain of three sessions (root, child, grandchild). A second agent resumes the
/// root. The announcements of the tree go first, the parent before the child. Then each session
/// sends its history under its own session id. All of it comes before the response.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SubagentSessionsReplayTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "SubagentSessionsReplayTests"

  /// The first text of the grandchild in the recording. The replay of its history holds it.
  private static let leafText = "LEAF-STARTED-TEXT"

  /// The id of the request in the trace of the validator.
  private static let requestId = RequestId.number(1)

  /// The wire of one resume of the chain.
  private struct ResumedWire {
    /// The second agent.
    let fixture: ScriptedPromptFixture

    /// The chain that the first agent recorded.
    let recording: ResumeNestedSessionsTests.Recording

    /// What the agent sent for the request, in wire order. It is complete when the response
    /// arrived.
    let updates: [UpdateSessionNotification]

    /// The wire as a trace for the validator: the request, the updates, the response.
    var trace: [WireTraceEvent] {
      [.resumeRequest(id: SubagentSessionsReplayTests.requestId, sessionId: recording.root)]
        + updates.map { .update(sessionId: $0.sessionId, update: $0.update) }
        + [.resumeResponse(id: SubagentSessionsReplayTests.requestId)]
    }

    /// The notifications of one session, in wire order.
    ///
    /// - Parameter session: The session.
    /// - Returns: The notifications that name it.
    func updates(of session: SessionId) -> [UpdateSessionNotification] {
      updates.filter { $0.sessionId == session }
    }

    /// The position of the announcement of a child, on the stream of its parent.
    ///
    /// - Parameter child: The announced child.
    /// - Returns: The position, or `nil` when the wire holds no announcement of it.
    func announcement(of child: SessionId) -> Int? {
      updates.firstIndex { notification in
        if case .subagentUpdate(let update) = notification.update {
          return update.sessionId == child
        }
        return false
      }
    }
  }

  // MARK: - Fixtures

  /// Records the chain with an orderly shutdown, resumes its root in a second agent, and reads what the agent sent.
  ///
  /// - Parameter replayFrom: The replay cursor of the request, or `nil` for none.
  /// - Returns: The wire of the resume.
  /// - Throws: Whatever the fixture or the request throws.
  private static func resume(replayFrom: ReplayFrom?) async throws -> ResumedWire {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-second", workingDirectory: recording.cwd)
    let countBefore = await fixture.collector.updates.count
    _ = try await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: recording.cwd.path), sessionId: recording.root,
        replayFrom: replayFrom))
    let updates = Array(await fixture.collector.updates.dropFirst(countBefore))
    return ResumedWire(fixture: fixture, recording: recording, updates: updates)
  }

  /// The text of an update, as the JSON that goes on the wire.
  ///
  /// - Parameter update: The update.
  /// - Returns: The JSON text.
  private static func json(of update: SessionUpdate) -> String {
    let data = (try? JSONEncoder().encode(update)) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  /// Whether an update names the `agents` tool.
  ///
  /// - Parameter update: The update.
  /// - Returns: `true` for a tool call update of the `agents` tool.
  private static func isAgentsCall(_ update: SessionUpdate) -> Bool {
    if case .toolCallUpdate(let call) = update {
      return call.name == .value(AgentsToolTests.agentsToolName)
    }
    return false
  }

  // MARK: - The announcements

  /// The root announces the child before the child announces the grandchild.
  @Test
  func theParentIsAnnouncedBeforeTheChild() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))
    let recording = wire.recording

    let childAnnouncement = try #require(wire.announcement(of: recording.child))
    let leafAnnouncement = try #require(wire.announcement(of: recording.leaf))

    #expect(childAnnouncement < leafAnnouncement)
    await wire.fixture.close()
  }

  /// The announcement of a child goes on the stream of its parent.
  @Test
  func theGrandchildIsAnnouncedOnTheStreamOfTheChild() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))
    let recording = wire.recording

    let announced = AnnouncedChild.first(in: wire.updates, on: recording.child)

    #expect(announced == recording.leaf)
    await wire.fixture.close()
  }

  /// A session sends no event before its announcement.
  @Test
  func noEventOfAChildComesBeforeItsAnnouncement() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))
    let recording = wire.recording

    let firstOfChild = try #require(wire.updates.firstIndex { $0.sessionId == recording.child })
    let firstOfLeaf = try #require(wire.updates.firstIndex { $0.sessionId == recording.leaf })

    #expect(try #require(wire.announcement(of: recording.child)) < firstOfChild)
    #expect(try #require(wire.announcement(of: recording.leaf)) < firstOfLeaf)
    await wire.fixture.close()
  }

  /// The replayed announcement keeps the capabilities out. They are current state, and a
  /// snapshot before the response is history.
  @Test
  func aReplayedAnnouncementCarriesNoCapabilities() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))

    let carried = wire.updates.contains { notification in
      if case .subagentUpdate(let update) = notification.update {
        return update.capabilities != .unchanged
      }
      return false
    }

    #expect(!carried)
    await wire.fixture.close()
  }

  // MARK: - The history of each session

  /// The history of the grandchild goes out under its own session id.
  @Test
  func theHistoryOfTheGrandchildIsReplayedUnderItsOwnId() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))

    let texts = wire.updates(of: wire.recording.leaf).map { Self.json(of: $0.update) }

    #expect(texts.contains { $0.contains(Self.leafText) })
    await wire.fixture.close()
  }

  /// The history of the child goes out under its own session id: its `agents` call.
  @Test
  func theHistoryOfTheChildIsReplayedUnderItsOwnId() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))

    let updates = wire.updates(of: wire.recording.child).map(\.update)

    #expect(updates.contains(where: Self.isAgentsCall))
    await wire.fixture.close()
  }

  /// The history of the grandchild stays out of the stream of the root.
  @Test
  func theHistoryOfTheGrandchildIsNotOnTheStreamOfTheRoot() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))

    let texts = wire.updates(of: wire.recording.root).map { Self.json(of: $0.update) }

    #expect(!texts.contains { $0.contains(Self.leafText) })
    await wire.fixture.close()
  }

  // MARK: - What a replay never sends

  /// A replay sends no request of the agent to the client.
  @Test
  func theReplaySendsNoElicitationRequest() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))

    let requests = await wire.fixture.harness.elicitations?.creates

    #expect(requests?.isEmpty == true)
    await wire.fixture.close()
  }

  /// A replay sends no `state_update` for a child. It is a current fact, and it comes after the
  /// response.
  @Test
  func theReplaySendsNoStateOfAChild() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))
    let root = wire.recording.root

    let childStates = wire.updates.filter { notification in
      notification.sessionId != root && notification.update.isStateUpdate
    }

    #expect(childStates.isEmpty)
    await wire.fixture.close()
  }

  /// The trace of the whole resume follows the rules of the validator for sub-agent sessions.
  @Test
  func theWireOfTheResumeFollowsTheRulesOfTheValidator() async throws {
    let wire = try await Self.resume(replayFrom: .start(ReplayFromStart()))

    let violations = SubagentWireTraceValidator().validate(wire.trace)

    #expect(violations == [])
    await wire.fixture.close()
  }

  // MARK: - No replay

  /// A resume with no `replayFrom` sends no history of any session.
  @Test
  func aResumeWithNoReplayFromSendsNoHistoryOfTheChildren() async throws {
    let wire = try await Self.resume(replayFrom: nil)
    let recording = wire.recording

    #expect(wire.updates(of: recording.child).isEmpty)
    #expect(wire.updates(of: recording.leaf).isEmpty)
    await wire.fixture.close()
  }

  /// A resume with no `replayFrom` sends no message of the root.
  @Test
  func aResumeWithNoReplayFromSendsNoMessageOfTheRoot() async throws {
    let wire = try await Self.resume(replayFrom: nil)

    let messages = wire.updates.filter { WireItem.of(update: $0.update) == .message }

    #expect(messages.isEmpty)
    await wire.fixture.close()
  }
}
