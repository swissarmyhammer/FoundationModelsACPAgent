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

  /// The id of the skill that the `skills:` key of the web agent preloads.
  private static let probeSkillID = "run-tools-probe"

  /// The template text that tells the shell value and the web value, with
  /// `prefix` before each marker.
  ///
  /// - Parameter prefix: The start of each marker.
  /// - Returns: The template text.
  private static func toolGatedText(prefix: String) -> String {
    "{% if tools.shell.enabled %}\(prefix)-SHELL-ON{% else %}\(prefix)-SHELL-OFF{% endif %} "
      + "{% if tools.web.enabled %}\(prefix)-WEB-ON{% else %}\(prefix)-WEB-OFF{% endif %}"
  }

  /// The start of each marker of the body of the web agent.
  private static let bodyMarkerPrefix = "RUN-BODY"

  /// The start of each marker of the preloaded skill.
  private static let skillMarkerPrefix = "RUN-SKILL"

  /// The markers that a run of an agent with `tools: [web]` renders: the
  /// shell is off and the web is on, in the body and in the preloaded skill.
  private static let webRunMarkers: [String] = [
    "\(bodyMarkerPrefix)-SHELL-OFF", "\(bodyMarkerPrefix)-WEB-ON",
    "\(skillMarkerPrefix)-SHELL-OFF", "\(skillMarkerPrefix)-WEB-ON",
  ]

  /// The `SKILL.md` of the preloaded skill: its body tells the shell value
  /// and the web value.
  private static let probeSkillMarkdown = """
    ---
    name: \(probeSkillID)
    description: Tells the shell value and the web value.
    ---

    \(toolGatedText(prefix: skillMarkerPrefix))
    """

  /// Writes ``childAgent`` with `tools`, the `skills:` preload of the probe
  /// skill, and a body that tells the shell value and the web value. It also
  /// writes the probe skill into the project skills layer of `cwd`.
  ///
  /// - Parameters:
  ///   - tools: The value of the `tools:` key.
  ///   - cwd: The working directory.
  /// - Throws: The write error.
  private static func writeWebAgent(tools: String, in cwd: URL) throws {
    try writeProbeAgent(keys: ["tools: \(tools)"], in: cwd)
  }

  /// Writes ``childAgent`` with the frontmatter `keys`, the `skills:` preload
  /// of the probe skill, and a body that tells the shell value and the web
  /// value. It also writes the probe skill into the project skills layer of
  /// `cwd`.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the agent, before its `skills:` key.
  ///   - cwd: The working directory.
  /// - Throws: The write error.
  private static func writeProbeAgent(keys: [String], in cwd: URL) throws {
    try AgentFolderFixture.writeProjectAgent(
      id: childAgent, in: cwd, extraKeys: keys + ["skills: [\(probeSkillID)]"],
      body: toolGatedText(prefix: bodyMarkerPrefix))
    try writeSkillFixture(
      id: probeSkillID, markdown: probeSkillMarkdown,
      under: cwd.appendingPathComponent(".\(ToolCatalog.skillsDotfolderName)", isDirectory: true))
  }

  /// The markers of ``webRunMarkers`` that `instructions` does not hold.
  ///
  /// - Parameter instructions: The instructions of a run.
  /// - Returns: The missing markers.
  private static func missingWebRunMarkers(in instructions: String) -> [String] {
    webRunMarkers.filter { marker in !instructions.contains(marker) }
  }

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

  /// A new run of an agent with `tools: [web]` renders its body and its preloaded skill with
  /// `tools.shell.enabled` as `false` and `tools.web.enabled` as `true`.
  @Test
  func aNewRunOfAWebAgentRendersItsBodyAndItsSkillWithTheShellOffAndTheWebOn() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-web-repo")
    try Self.writeWebAgent(tools: "[web]", in: cwd)

    let instructions = try await Self.newRunInstructions(in: cwd, label: "\(Self.label)-web")

    #expect(Self.missingWebRunMarkers(in: instructions).isEmpty, "\(instructions)")
  }

  /// A new run of an agent with `disallowedTools: [skills]` still renders the body of its
  /// `skills:` preload. A run has no endpoint, thus the key removes the `skills` tool of the run
  /// (decision of 2026-11-12). The key does not remove the preload.
  @Test
  func aNewRunOfAnAgentWithDisallowedSkillsRendersItsPreloadedSkill() async throws {
    let cwd = makeResolvedDirectory(label: "\(Self.label)-no-skills-repo")
    try Self.writeProbeAgent(keys: [AgentToolKeys.noSkills], in: cwd)

    let instructions = try await Self.newRunInstructions(in: cwd, label: "\(Self.label)-no-skills")

    #expect(instructions.contains(Self.skillMarkerPrefix), "\(instructions)")
  }

  /// Starts a run of ``childAgent`` from a root session in `cwd`, and gives the leading
  /// instructions of the session of the run. The run holds until it has its instructions.
  ///
  /// - Parameters:
  ///   - cwd: The working directory that holds the agent.
  ///   - label: The directory label of the agent.
  /// - Returns: The instructions text of the run.
  /// - Throws: An issue when the root session announces no child, or the child has no
  ///   instructions.
  private static func newRunInstructions(in cwd: URL, label: String) async throws -> String {
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
      script: script, label: label, workingDirectory: cwd)
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
    let instructions = try await Self.instructions(of: child, on: fixture)
    hold.release()
    _ = try? await prompt.value
    await fixture.close()
    return instructions
  }

  /// A restored run of an agent with `tools: [agents, web]` renders its body and its preloaded
  /// skill with `tools.shell.enabled` as `false` and `tools.web.enabled` as `true`. The
  /// definition changes between the record and the resume, so the instructions come from the
  /// restore. The `agents` entry keeps the tool that the child used to start its own child.
  @Test
  func aRestoredRunOfAWebAgentRendersItsBodyAndItsSkillWithTheShellOffAndTheWebOn()
    async throws
  {
    let recording = try await ResumeNestedSessionsTests.recordShutDownChain()
    try Self.writeWebAgent(tools: "[agents, web]", in: recording.cwd)
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-web-second", workingDirectory: recording.cwd)
    try await ResumeNestedSessionsTests.resumeRoot(of: recording, on: fixture)

    let instructions = try await Self.instructions(of: recording.child, on: fixture)

    #expect(Self.missingWebRunMarkers(in: instructions).isEmpty, "\(instructions)")
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
