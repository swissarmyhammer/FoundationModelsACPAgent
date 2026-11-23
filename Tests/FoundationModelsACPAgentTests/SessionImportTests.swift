import ACPImport
import ACPMarkdown
import Foundation
import FoundationModels
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The copy of a session of another agent into a new session of the agent (D209, D212): the
/// continue of an external session of the importer of the agent reads a Claude Code session
/// file of a fixture root, the Router directory writes the new recording with the origin
/// `import`, and the agent writes the history of the new session.
///
/// Each test runs a scripted agent in the test process. The suite trait closes each harness of
/// a test whose body throws.
@Suite(.closesHarnesses) struct SessionImportTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "SessionImportTests"

  /// The source id of the Claude Code session of the root.
  private static let claudeID = "9c1e0000-0000-4000-8000-000000000003"

  /// The custom title of the Claude Code session.
  private static let title = "Timer fix"

  /// The name of a second copy of the same source: the slug of ``title`` with the next free
  /// number.
  private static let secondName = "timer-fix-2"

  /// The text of the agent message of the scripted model.
  private static let scriptedAnswer = "Next answer."

  /// The prompt that the test sends to the new session.
  private static let nextPrompt = "Next question."

  /// The most sessions of a page of a search.
  private static let pageLimit = 10

  // MARK: - Fixtures

  /// A scripted agent with a Claude Code root whose session works in the folder of the
  /// fixture.
  private struct ImportFixture {
    /// The scripted agent and its session.
    let fixture: ScriptedPromptFixture

    /// The file of the source session.
    let file: URL

    /// The agent under test.
    var agent: RoutedACPAgent { fixture.harness.agent }

    /// Makes the fixture.
    ///
    /// - Parameter name: The label of the test.
    /// - Returns: The fixture.
    /// - Throws: The error of a write or of the fixture.
    static func make(name: String) async throws -> ImportFixture {
      let base = makeResolvedDirectory(label: "\(label)-\(name)")
      let cwd = base.appendingPathComponent("repo", isDirectory: true)
      try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
      let root = base.appendingPathComponent(".claude", isDirectory: true)
      let file = try ImportSessionFiles.writeClaudeCode(
        id: claudeID, folder: cwd, title: title, withAnswer: true, in: root)
      let fixture = try await ScriptedPromptFixture.make(
        script: [.textDelta(scriptedAnswer), .endPass], label: "\(label)-\(name)",
        workingDirectory: cwd, importRoots: [.claudeCode: root])
      return ImportFixture(fixture: fixture, file: file)
    }

    /// Continues the source session in a new session, through the agent as the host of the
    /// external sessions.
    ///
    /// - Parameter folder: The folder of the new session, or `nil` for the folder of the
    ///   source.
    /// - Returns: The summary of the new session.
    /// - Throws: The error of the continue.
    func importSource(folder: URL? = nil) async throws -> SessionSummary {
      let host: any ExternalSessionHost = agent.sessionImporter
      return try await host.continueExternalSession(
        ExternalSessionContinueRequest(
          session: ExternalSessionID(
            source: ImportSourceAgent.claudeCode.rawValue, sourceID: claudeID),
          folder: folder))
    }

    /// The updates of the source session, as the reader reads them.
    ///
    /// - Returns: The updates.
    /// - Throws: The error of the read.
    func sourceUpdates() throws -> [SessionUpdate] {
      try ClaudeCodeSessionReader(sourceID: claudeID).read(from: FileByteSource(forReadingFrom: file)).updates
    }

    /// Resumes a session with the replay from the start.
    ///
    /// - Parameter session: The session.
    /// - Returns: The updates of the session that the client got after the request.
    /// - Throws: The error of the resume.
    func resume(_ session: ULID) async throws -> [SessionUpdate] {
      let sessionId = SessionId(rawValue: session.description)
      let countBefore = await fixture.collector.updates.count
      _ = try await fixture.harness.connection.resumeSession(
        ResumeSessionRequest(
          cwd: AbsolutePath(rawValue: fixture.cwd.path), sessionId: sessionId,
          replayFrom: .start(ReplayFromStart())))
      return await fixture.collector.updates.dropFirst(countBefore)
        .filter { $0.sessionId == sessionId }.map(\.update)
    }
  }

  /// The text of each agent message of the updates of a replay, joined. A replay sends each
  /// message as one whole update.
  ///
  /// - Parameter updates: The updates.
  /// - Returns: The text.
  private static func replayedAgentText(of updates: [SessionUpdate]) -> String {
    updates.flatMap { update -> [String] in
      guard case .agentMessage(let message) = update, case .value(let blocks) = message.content
      else { return [] }
      return blocks.compactMap { block in
        guard case .text(let text) = block else { return nil }
        return text.text
      }
    }.joined()
  }

  /// The request of a search of the word of the answer of the source.
  ///
  /// - Returns: The request.
  /// - Throws: The refusal of a query that does not parse.
  private static func answerWordRequest() throws -> SessionSearchRequest {
    SessionSearchRequest(
      query: try SessionSearchQuery(parsing: ImportSessionFiles.claudeCodeAnswerWord),
      sessions: nil, includeArchived: false, preferredFolder: nil, session: nil,
      limit: pageLimit, cursor: nil)
  }

  // MARK: - Tests

  @Test("an imported session is in the list of the directory with the origin import")
  func theImportIsListedWithTheOriginImport() async throws {
    let imported = try await ImportFixture.make(name: "list")
    defer { await imported.fixture.close() }

    let result = try await imported.importSource()

    let summaries = try await imported.agent.sessionDirectory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    #expect(summaries.first { $0.id == result.id }?.origin == .import)
  }

  @Test("an imported session is in the list of the directory with the provenance of the source")
  func theImportIsListedWithTheProvenance() async throws {
    let imported = try await ImportFixture.make(name: "provenance")
    defer { await imported.fixture.close() }

    let result = try await imported.importSource()

    let summaries = try await imported.agent.sessionDirectory.sessions(
      matching: SessionQuery(includesRecorded: true, limit: .max))
    #expect(
      summaries.first { $0.id == result.id }?.importedFrom?.sourcePath
        == imported.file.path)
  }

  @Test("session/resume of an imported session replays the updates of the source")
  func theResumeReplaysTheSource() async throws {
    let imported = try await ImportFixture.make(name: "resume")
    defer { await imported.fixture.close() }
    let result = try await imported.importSource()

    let updates = try await imported.resume(result.id)

    #expect(Self.replayedAgentText(of: updates).contains(ImportSessionFiles.claudeCodeAnswer))
  }

  @Test("the export of an imported session is the Markdown of the source")
  func theExportIsTheMarkdownOfTheSource() async throws {
    let imported = try await ImportFixture.make(name: "export")
    defer { await imported.fixture.close() }
    let result = try await imported.importSource()
    let summary = try #require(await imported.agent.sessionDirectory.summary(of: result.id))
    let expected = SessionMarkdown.render(
      updates: SessionMergeEngine(replaying: try imported.sourceUpdates()).replayedTranscriptUpdates,
      options: SessionMarkdown.Options(
        includeThoughts: false, title: summary.title, agentName: summary.agentName,
        labels: .english))

    let markdown = try await imported.agent.transcriptMarkdown(
      of: result.id, includeThoughts: false)

    #expect(markdown == expected)
  }

  @Test("a search finds a word of an imported turn")
  func aSearchFindsAWordOfTheImport() async throws {
    let imported = try await ImportFixture.make(name: "search")
    defer { await imported.fixture.close() }
    let result = try await imported.importSource()
    let request = try Self.answerWordRequest()
    let agent = imported.agent

    try await pollIndexUntil {
      try await agent.searchTranscripts(request).sessions.contains { $0.session == result.id }
    }

    #expect(
      try await agent.searchTranscripts(request).sessions.contains {
        $0.session == result.id
      })
  }

  @Test("the first prompt of an imported session goes to the model after the imported turn")
  func theFirstPromptFollowsTheImportedTurn() async throws {
    let imported = try await ImportFixture.make(name: "prompt")
    defer { await imported.fixture.close() }
    let result = try await imported.importSource()
    _ = try await imported.resume(result.id)
    let sessionId = SessionId(rawValue: result.id.description)
    let idlesBefore = ScriptedPromptFixture.idleCount(
      in: await imported.fixture.collector.updates)

    try await ScriptedPromptFixture.runPrompt(
      AgentClientHarness.makePromptRequest(sessionId: sessionId, text: Self.nextPrompt),
      through: imported.fixture.harness, count: idlesBefore + 1)

    let live = try #require(await imported.agent.sessions[sessionId]?.session)
    let texts = ImportedTranscriptReading.texts(of: Transcript(entries: Array(await live.transcript)))
    #expect(
      Array(texts.drop { $0 == "other" }.prefix(2)) == [
        "prompt: \(ImportSessionFiles.claudeCodeQuestion)",
        "response: Tool Bash: \(ImportSessionFiles.claudeCodeToolCommand): completed\n"
          + "\(ImportSessionFiles.claudeCodeToolOutput)\n\n\(ImportSessionFiles.claudeCodeAnswer)",
      ])
  }

  @Test("a second continue of the same source makes a second session with the next free name")
  func aSecondImportGetsTheNextFreeName() async throws {
    let imported = try await ImportFixture.make(name: "second")
    defer { await imported.fixture.close() }
    _ = try await imported.importSource()

    let second = try await imported.importSource()

    #expect(second.title == Self.secondName)
  }

  @Test("a continue into a folder that does not exist makes no folder")
  func anImportIntoAMissingFolderMakesNoFolder() async throws {
    let imported = try await ImportFixture.make(name: "missing")
    defer { await imported.fixture.close() }
    let missing = imported.fixture.cwd.appendingPathComponent("missing", isDirectory: true)

    await #expect(throws: ExternalSessionError.folderUnavailable(missing)) {
      try await imported.importSource(folder: missing)
    }

    #expect(!FileManager.default.fileExists(atPath: missing.path))
  }
}
