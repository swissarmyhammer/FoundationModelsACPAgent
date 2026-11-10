import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import Testing

@testable import FoundationModelsACPAgent

/// The instructions of an agent run (task ^56j0zg1). Each run that the `agents` tool starts, and
/// each run that a resume restores, starts its instructions with the style text, then the text of
/// the `AGENTS.md` file of its working folder, then the body of its agent.
///
/// The test reads the leading `.instructions` entry of the transcript of the child session. The
/// table of the agent holds that session.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct SubagentInstructionsTests {
  /// The directory label of the suite.
  private static let label = "SubagentInstructionsTests"

  /// The agent that the root session starts. The restore test uses the chain of
  /// ``ResumeNestedSessionsTests``, so both tests use its agent.
  private static let childAgent = ResumeNestedSessionsTests.childAgent

  /// The prompt of the root session. It starts the child.
  private static let rootPrompt = "ROOT-INSTRUCTIONS-MARKER"

  /// The prompt of the child.
  private static let childPrompt = "CHILD-INSTRUCTIONS-MARKER"

  /// The text that the child gives before it waits.
  private static let childStartedText = "CHILD-STARTED-TEXT"

  /// The `AGENTS.md` text of the working folder of a new run.
  private static let agentsMdText = "AGENTS-MD-RULES: the rules of the project."

  /// The `AGENTS.md` text that the working folder gets after the record and before the resume.
  private static let changedAgentsMdText = "AGENTS-MD-CHANGED-RULES: the new rules of the project."

  /// The text between two parts of the instructions of a run. FoundationModelsAgents joins the
  /// preamble, the `AGENTS.md` text and the body with it.
  private static let runPartSeparator = "\n\n"

  /// The expected start of the instructions of a run of ``childAgent``: the style text, then
  /// `agentsMd`, then the rendered body of the agent. The runner of the root session of
  /// `fixture` renders the body, as it renders the body of a run.
  ///
  /// - Parameters:
  ///   - agentsMd: The `AGENTS.md` text of the working folder of the run.
  ///   - fixture: The agent that holds the root session.
  /// - Returns: The expected start.
  /// - Throws: An issue when the root session has no runner or the catalog has no such agent, or
  ///   the render failure of the agent.
  private static func expectedStart(
    agentsMd: String, on fixture: ScriptedPromptFixture
  ) async throws -> String {
    let root = try #require(await fixture.harness.agent.sessions[fixture.sessionId])
    let runner = try #require(root.surface.agents?.runner)
    let definition = try #require(runner.catalog().definition(named: childAgent))
    let body = try await runner.sessionAgentInstructions(for: definition).body
    return [StyleInstructions.text, agentsMd, body].joined(separator: runPartSeparator)
  }

  /// The leading instructions of the session of `sessionId` in the table of `fixture`.
  ///
  /// - Parameters:
  ///   - sessionId: The session.
  ///   - fixture: The agent that holds the session.
  /// - Returns: The instructions text.
  /// - Throws: An issue when the table has no such session, or its transcript starts with a
  ///   different entry.
  private static func instructions(
    of sessionId: SessionId, on fixture: ScriptedPromptFixture
  ) async throws -> String {
    let entry = try #require(await fixture.harness.agent.sessions[sessionId])
    return try #require(await entry.session.transcript.leadingInstructionsText)
  }

  /// A run that the `agents` tool starts in a working folder with an `AGENTS.md` starts its
  /// instructions with the style text, then the `AGENTS.md` text, then the body of its agent.
  @Test
  func aNewRunStartsWithTheStyleTextThenTheAgentsMdTextThenTheBody() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-repo")
    try AgentsFileFixture.write(Self.agentsMdText, in: cwd)
    try AgentsToolTests.writeAgent(named: Self.childAgent, in: cwd)
    let hold = ScriptedHold()
    let script: [ScriptedPassStep] = [
      .onPrompt(
        containing: Self.childPrompt,
        play: [.textDelta(Self.childStartedText), .holdUntilReleased(hold), .endPass]),
      .onPrompt(
        containing: Self.rootPrompt,
        play: [
          AgentsToolTests.startAgentCall(agent: Self.childAgent, prompt: Self.childPrompt),
          .endPass,
        ]),
      .endPass,
    ]
    let fixture = try await ScriptedPromptFixture.make(
      script: script, label: Self.label, workingDirectory: cwd)
    let root = fixture.sessionId
    let prompt = Task {
      try await fixture.harness.connection.prompt(
        AgentClientHarness.makePromptRequest(sessionId: root, text: Self.rootPrompt))
    }
    let updates = try await fixture.collector.wait(for: "the first text of the child") { updates in
      ScriptedPromptFixture.agentText(in: updates.filter { $0.sessionId != root })
        .contains(Self.childStartedText)
    }
    let child = try #require(AnnouncedChild.first(in: updates, on: root))

    let expected = try await Self.expectedStart(agentsMd: Self.agentsMdText, on: fixture)

    let instructions = try await Self.instructions(of: child, on: fixture)

    #expect(instructions.hasPrefix(expected), "\(instructions.prefix(expected.count))")
    hold.release()
    _ = try? await prompt.value
    await fixture.close()
  }

  /// A run that a resume restores starts its instructions with the style text, then the
  /// `AGENTS.md` text of its working folder, then the body of its agent. The `AGENTS.md` text
  /// changes between the record and the resume, so the transcript shows the instructions that the
  /// restore made, not the recorded ones.
  @Test
  func aRestoredRunStartsWithTheStyleTextThenTheAgentsMdTextThenTheBody() async throws {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    try AgentsFileFixture.write(Self.changedAgentsMdText, in: recording.cwd)
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-second", workingDirectory: recording.cwd)
    try await ResumeNestedSessionsTests.resumeRoot(of: recording, on: fixture)
    let expected = try await Self.expectedStart(agentsMd: Self.changedAgentsMdText, on: fixture)

    let instructions = try await Self.instructions(of: recording.child, on: fixture)

    #expect(instructions.hasPrefix(expected), "\(instructions.prefix(expected.count))")
    await fixture.close()
  }
}
