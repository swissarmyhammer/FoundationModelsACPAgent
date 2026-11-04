import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// A `session/resume` of a root that is live while its child runs. The request must never stop
/// the process: it ends with a response or with a clear error. ``HotResumeTests`` holds the rules
/// of the hot resume.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct ResumeLiveSessionTests {
  /// The prefix of the folders of each fixture of this suite.
  private static let label = "ResumeLiveSessionTests"

  /// The first text of the child.
  private static let childText = "LIVE-RESUME-CHILD-TEXT"

  @Test
  func aResumeOfALiveRootWithARunningChildDoesNotStopTheProcess() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-repo")
    try AgentsToolTests.writeAgent(named: "worker", in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: "LIVE-RESUME-CHILD",
        play: [.textDelta(Self.childText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: "LIVE-RESUME-ROOT",
        play: [AgentsToolTests.startAgentCall(agent: "worker", prompt: "LIVE-RESUME-CHILD"), .endPass]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: Self.label, workingDirectory: cwd,
      projectConfigYAML: "tools:\n  codeContext: true\n")
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: "LIVE-RESUME-ROOT"))
    }
    _ = try await fixture.collector.wait(for: "the text of the child") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(Self.childText)
    }

    // A response or an error is fine. A stop of the process is not.
    _ = try? await fixture.harness.connection.resumeSession(
      ResumeSessionRequest(
        cwd: AbsolutePath(rawValue: cwd.path), sessionId: root, replayFrom: .start(ReplayFromStart())))

    hold.release()
    _ = try? await prompt.value
    await fixture.close()
  }
}
