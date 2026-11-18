import Foundation
import FoundationModels
import FoundationModelsACPAgentTestSupport
import FoundationModelsAgents
import FoundationModelsMultitool
import FoundationModelsSkills
import Testing

@testable import FoundationModelsACPAgent

/// The `skills: [sessions]` preload of the session agent (D200, task ^bmtkvpw).
///
/// The skills stack of each session has the built-in skills of Multitool as its defaults layer
/// (^zx4k6r4). Thus a session agent that names the built-in `sessions` skill in its `skills:` key
/// gets the body of that skill in its instructions, after the body of the agent. An
/// `Instructions.md` replaces the base prompt and the skill bodies, but the `skills` tool can
/// still load the skill.
///
/// Each test opens one session of a stub agent over throwaway folders. The stub agent sets no
/// `SKILLS_DEFAULTS_DIR`, thus its skills stack has the built-in layer.
@Suite(.closesHarnesses) struct SessionsSkillPreloadTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "SessionsSkillPreloadTests"

  /// The id of the built-in skill that the agent preloads.
  private static let sessionsSkillID = "sessions"

  /// The `skills:` key that preloads the built-in skill.
  private static let sessionsSkillKey = "skills: [\(sessionsSkillID)]"

  /// The marker body of the session agent.
  private static let agentBody = "SESSIONS-PRELOAD-AGENT-BODY"

  /// The marker text of the project `Instructions.md`.
  private static let instructionsFileText = "SESSIONS-PRELOAD-INSTRUCTIONS-FILE"

  /// The `skills` tool call that loads the built-in skill.
  private static let useSessionsSkillJSON = #"{"op": "use skill", "id": "\#(sessionsSkillID)"}"#

  // MARK: - Helpers

  /// One open session of a new stub agent.
  struct OpenedSession {
    /// The assembled instructions of the session.
    let instructions: String

    /// The tool surface of the session.
    let surface: SessionSurface
  }

  /// The rendered body of the built-in skill, with no leading or trailing white space: the text
  /// that the preload appends. The assembler trims the text of the session agent, thus the
  /// instructions do not hold the blank lines around the body.
  ///
  /// - Returns: The body.
  /// - Throws: What the render of the skill throws.
  private static func sessionsSkillBody() async throws -> String {
    try await SkillsRegistry(roots: [BuiltinSkills.directory], mode: .open)
      .call(id: sessionsSkillID)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Writes the project `default` agent of `cwd` with the marker body and the frontmatter
  /// `keys`.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the agent, after its name and its description.
  ///   - cwd: The working directory.
  /// - Throws: The directory-creation or write error.
  private static func writeDefaultAgent(keys: [String], in cwd: URL) throws {
    try AgentFolderFixture.writeProjectAgent(
      id: ConfigOptions.defaultAgentValue, in: cwd, extraKeys: keys, body: agentBody)
  }

  /// Writes the project `Instructions.md` of `cwd`, in the configuration dotfolder of the stub
  /// agent.
  ///
  /// - Parameter cwd: The working directory.
  /// - Throws: The directory-creation or write error.
  private static func writeInstructionsFile(in cwd: URL) throws {
    try TestFileFixture.write(
      instructionsFileText, named: InstructionsAssembler.instructionsFileName,
      in: cwd.appendingPathComponent(".\(AgentClientHarness.dotfolderName)", isDirectory: true))
  }

  /// Opens one session in `cwd` on a new stub agent.
  ///
  /// - Parameter cwd: The working directory.
  /// - Returns: The session.
  /// - Throws: What the agent or `session/new` throws, or an issue when the table of the agent
  ///   has no such session.
  private static func openSession(in cwd: URL) async throws -> OpenedSession {
    let agent = try await AgentClientHarness.makeInitializedAgent(label: label)
    let response = try await agent.newSession(AgentClientHarness.makeNewSessionRequest(cwd: cwd))
    let entry = try #require(await agent.sessions[response.sessionId])
    return OpenedSession(instructions: entry.instructions, surface: entry.surface)
  }

  /// Opens one session in a new working directory whose `default` agent has the frontmatter
  /// `keys`.
  ///
  /// - Parameters:
  ///   - keys: The frontmatter lines of the agent.
  ///   - name: The part of the folder label that names the test.
  ///   - withInstructionsFile: `true` to write a project `Instructions.md` too.
  /// - Returns: The session.
  /// - Throws: What the writes or ``openSession(in:)`` throw.
  private static func openSession(
    agentKeys keys: [String], name: String, withInstructionsFile: Bool = false
  ) async throws -> OpenedSession {
    let cwd = makeResolvedDirectory(label: "\(label)-\(name)")
    try writeDefaultAgent(keys: keys, in: cwd)
    if withInstructionsFile {
      try writeInstructionsFile(in: cwd)
    }
    return try await openSession(in: cwd)
  }

  // MARK: - The preload

  /// A default agent with `skills: [sessions]` gets the body of the built-in skill in its
  /// instructions, after the body of the agent.
  @Test func theSessionsSkillBodyFollowsTheAgentBody() async throws {
    let session = try await Self.openSession(agentKeys: [Self.sessionsSkillKey], name: "preload")
    let body = try await Self.sessionsSkillBody()

    let agentEnd = try #require(session.instructions.range(of: Self.agentBody)).upperBound
    let skillRange = try #require(
      session.instructions.range(of: body), "\(session.instructions.prefix(400))")
    #expect(agentEnd <= skillRange.lowerBound)
  }

  /// A default agent with no `skills:` key does not get the body of the built-in skill.
  @Test func anAgentWithNoSkillsKeyDoesNotGetTheSessionsSkillBody() async throws {
    let session = try await Self.openSession(agentKeys: [], name: "no-key")
    let body = try await Self.sessionsSkillBody()

    #expect(!session.instructions.contains(body))
  }

  /// The catalog of the runner gives no `unknownSkill` warning for the `sessions` entry: the
  /// built-in layer gives the skill.
  @Test func theCatalogGivesNoUnknownSkillWarningForTheSessionsSkill() async throws {
    let session = try await Self.openSession(
      agentKeys: [Self.sessionsSkillKey], name: "catalog")
    let catalog = try #require(session.surface.agents?.runner).catalog()
    _ = try #require(catalog.definition(named: ConfigOptions.defaultAgentValue))

    let unknown = catalog.diagnostics.filter { diagnostic in diagnostic.code == .unknownSkill }

    #expect(unknown.isEmpty, "\(unknown)")
  }

  // MARK: - The `Instructions.md` replacement

  /// With an `Instructions.md`, the instructions do not hold the body of the preloaded skill.
  @Test func anInstructionsFileReplacesTheSessionsSkillBody() async throws {
    let session = try await Self.openSession(
      agentKeys: [Self.sessionsSkillKey], name: "file", withInstructionsFile: true)
    let body = try await Self.sessionsSkillBody()
    try #require(session.instructions.contains(Self.instructionsFileText))

    #expect(!session.instructions.contains(body))
  }

  /// With an `Instructions.md`, the `skills` tool of the session still loads the built-in skill.
  @Test func withAnInstructionsFileTheSkillsToolLoadsTheSessionsSkill() async throws {
    let session = try await Self.openSession(
      agentKeys: [Self.sessionsSkillKey], name: "file-tool", withInstructionsFile: true)
    let tool = try #require(
      session.surface.tools.first { tool in tool.name == SkillOutputProtection.skillsToolName }
        as? SkillsCatalogTool)
    let body = try await Self.sessionsSkillBody()

    let loaded = try await tool.call(arguments: GeneratedContent(json: Self.useSessionsSkillJSON))

    #expect(loaded.contains(body), "\(loaded.prefix(400))")
  }
}
