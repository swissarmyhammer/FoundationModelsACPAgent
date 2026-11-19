import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The read of the wire of a `session/resume` on the connection of a ``ScriptedPromptFixture``
/// (``ScriptedPromptFixture/subscribeToTheResumeWire()``).
///
/// The fixture opens its own session with `session/new`. That session sends its default name
/// after the `session/new` response, and the fixture returns at the response. So under load the
/// update can come after the read starts. The resume request does not announce that session, so
/// an event of it in the trace makes the validator report `announceBeforeUse`.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ResumeWireTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ResumeWireTests"

  /// The seconds that a read of the wire waits for the response of the resume.
  private static let readWaitSeconds = 30

  /// The title of the live update that the fixture sends for its own session.
  private static let liveTitleOfTheOwnSession = "LIVE-TITLE-OF-THE-OWN-SESSION"

  /// The own session of the fixture sends a live update in a fixed order: after the read starts
  /// and before the resume request. The update is not part of the trace of the resume.
  @Test
  func aLiveUpdateOfTheOwnSessionOfTheFixtureIsNotInTheResumeTrace() async throws {
    let recording = try await ResumeNestedSessionsTests.recordInterruptedChain()
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: Self.label, workingDirectory: recording.cwd)
    let ownSession = fixture.sessionId
    let request = ResumeSessionRequest(
      cwd: AbsolutePath(rawValue: recording.cwd.path), sessionId: recording.root)

    let trace = try await fixture.subscribeToTheResumeWire().readResumeTrace(
      timeout: .seconds(Self.readWaitSeconds)
    ) {
      let title = SessionInfoUpdate(title: .value(Self.liveTitleOfTheOwnSession))
      await fixture.harness.agent.historySink(for: ownSession)(.sessionInfoUpdate(title))
      _ = try await fixture.harness.connection.resumeSession(request)
    }

    #expect(!trace.contains { $0.isUpdate(on: ownSession) })
    await fixture.close()
  }
}

extension WireTraceEvent {
  /// Whether this event is an update on the stream of `session`.
  ///
  /// - Parameter session: The session.
  /// - Returns: `true` for an update of that session.
  fileprivate func isUpdate(on session: SessionId) -> Bool {
    if case .update(let stream, _) = self {
      return stream == session
    }
    return false
  }
}
