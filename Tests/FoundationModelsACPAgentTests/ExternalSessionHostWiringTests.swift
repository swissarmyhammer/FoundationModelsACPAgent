import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import Testing

@testable import FoundationModelsACPAgent

/// The host of the external sessions (D212 step 3): the agent gives its ``AgentSessionImporter``
/// to the `sessions` tool and endpoint of each session as an `ExternalSessionHost`
/// (``CatalogContext/externalSessionHost``).
///
/// The tool tests run a scripted agent in the test process: the script calls an external session
/// operation of the `sessions` tool. The host tests call the host of the agent. Each test waits
/// until the index is idle first, because a query never waits for the build of the index.
@Suite(.closesHarnesses) struct ExternalSessionHostWiringTests {
  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "ExternalSessionHostWiringTests"

  /// The text of the prompt that makes the scripted model list the external sessions.
  private static let listMarker = "LIST-EXTERNAL-BY-TOOL"

  /// The text of the prompt that makes the scripted model read the external session.
  private static let readMarker = "READ-EXTERNAL-BY-TOOL"

  /// The name of the tool that the script calls.
  private static let sessionsName = "sessions"

  /// The source id of the Claude Code session of the root.
  private static let claudeID = "7c1e0000-0000-4000-8000-000000000003"

  /// The working folder of the Claude Code session of the root.
  private static let claudeFolder = URL(fileURLWithPath: "/work/app", isDirectory: true)

  /// The external session of the root.
  private static let session = ExternalSessionID(
    source: ImportSourceAgent.claudeCode.rawValue, sourceID: claudeID)

  // MARK: - Fixtures

  /// Makes a Claude Code root with one session that has an answer.
  ///
  /// - Returns: The root (`~/.claude`).
  /// - Throws: The error of the write.
  private static func makeClaudeRoot() throws -> URL {
    let root = makeResolvedDirectory(label: label).appendingPathComponent(".claude", isDirectory: true)
    try ImportSessionFiles.writeClaudeCode(
      id: claudeID, folder: claudeFolder, withAnswer: true, in: root)
    return root
  }

  /// Makes an agent whose script calls the `list external sessions` and the
  /// `read external session` operations at their markers.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The fixture, with its index idle.
  /// - Throws: The error of the fixture.
  private static func fixture(name: String) async throws -> ScriptedPromptFixture {
    try await fixture(name: name, root: try makeClaudeRoot())
  }

  /// Makes an agent as ``fixture(name:)`` does, over a given Claude Code root.
  ///
  /// - Parameters:
  ///   - name: The label of the test.
  ///   - root: The Claude Code root.
  /// - Returns: The fixture, with its index idle.
  /// - Throws: The error of the fixture.
  private static func fixture(name: String, root: URL) async throws -> ScriptedPromptFixture {
    let readArguments =
      #"{"op":"read external session","source":"claude-code","id":"\#(claudeID)"}"#
    let fixture = try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: listMarker,
          play: [
            .toolCall(name: sessionsName, argumentsJSON: #"{"op":"list external sessions"}"#),
            .endPass,
          ]),
        .onPrompt(
          containing: readMarker,
          play: [.toolCall(name: sessionsName, argumentsJSON: readArguments), .endPass]),
        .endPass,
      ],
      label: "\(label)-\(name)",
      importRoots: [.claudeCode: root])
    await fixture.harness.agent.sessionImporter.index.waitUntilIdle()
    return fixture
  }

  /// Runs a marker prompt, and gives the output of the tool calls of the session.
  ///
  /// - Parameters:
  ///   - marker: The text of the prompt.
  ///   - fixture: The fixture.
  /// - Returns: The output text.
  /// - Throws: The error of the prompt.
  private static func run(_ marker: String, on fixture: ScriptedPromptFixture) async throws
    -> String
  {
    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: marker)
    return try ToolOutputText.of(run.updates, in: fixture.sessionId)
  }

  // MARK: - The tool

  @Test("list external sessions through the sessions tool lists the session of the root")
  func theToolListsTheExternalSession() async throws {
    let fixture = try await Self.fixture(name: "list")
    defer { await fixture.close() }

    let output = try await Self.run(Self.listMarker, on: fixture)

    #expect(output.contains(Self.claudeID), "\(output)")
  }

  @Test("read external session through the sessions tool gives the text of the session")
  func theToolReadsTheExternalSession() async throws {
    let fixture = try await Self.fixture(name: "read")
    defer { await fixture.close() }

    let output = try await Self.run(Self.readMarker, on: fixture)

    #expect(output.contains(ImportSessionFiles.claudeCodeQuestion), "\(output)")
  }

  // MARK: - The host

  @Test("the updates of an external session give the user message of the file")
  func theUpdatesGiveTheUserMessage() async throws {
    let fixture = try await Self.fixture(name: "updates")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter

    var entries: [SessionTranscriptEntry] = []
    for try await batch in host.externalSessionUpdates(of: Self.session) {
      entries += batch.entries
    }

    let user = try #require(entries.first { $0.kind == "user_message_chunk" }, "\(entries)")
    guard case .object(let fields) = user.payload, case .object(let content)? = fields["content"]
    else {
      Issue.record("the user entry has no content: \(user)")
      return
    }
    #expect(content["text"] == .string(ImportSessionFiles.claudeCodeQuestion))
  }

  @Test("the updates of a session that the index does not hold end with unknownSession")
  func theUpdatesOfAnUnknownSessionEndWithTheError() async throws {
    let fixture = try await Self.fixture(name: "unknown")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let unknown = ExternalSessionID(source: ImportSourceAgent.claudeCode.rawValue, sourceID: "none")

    await #expect(throws: ExternalSessionError.unknownSession(unknown)) {
      for try await _ in host.externalSessionUpdates(of: unknown) {}
    }
  }

  @Test("continue of an external session makes a new session in the folder")
  func theContinueMakesANewSession() async throws {
    let fixture = try await Self.fixture(name: "continue")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let folder = makeResolvedDirectory(label: "\(Self.label)-continue-folder")

    let summary = try await host.continueExternalSession(
      ExternalSessionContinueRequest(session: Self.session, folder: folder, name: "Continued"))

    #expect(summary.title == "Continued")
    #expect(summary.workingDirectory.standardizedFileURL == folder.standardizedFileURL)
  }

  @Test("continue of a session that the index does not hold gives unknownSession")
  func theContinueOfAnUnknownSessionGivesTheError() async throws {
    let fixture = try await Self.fixture(name: "continue-unknown")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let unknown = ExternalSessionID(source: ImportSourceAgent.claudeCode.rawValue, sourceID: "none")

    await #expect(throws: ExternalSessionError.unknownSession(unknown)) {
      _ = try await host.continueExternalSession(
        ExternalSessionContinueRequest(session: unknown, folder: makeResolvedDirectory(label: Self.label)))
    }
  }

  @Test("a rebuild of the index of a source reads the session again and gives the same row")
  func theRebuildGivesTheSameRow() async throws {
    let fixture = try await Self.fixture(name: "rebuild")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let query = ExternalSessionQuery(limit: 10)
    let before = try await host.externalSessions(query)

    try await host.rebuildExternalSessionIndex(source: ImportSourceAgent.claudeCode.rawValue)
    await fixture.harness.agent.sessionImporter.index.waitUntilIdle()
    let after = try await host.externalSessions(query)

    #expect(after.sessions.map(\.id) == [Self.session])
    #expect(after.sessions == before.sessions)
  }

  @Test("a rebuild of a source with no access gives sourceUnreadable")
  func theRebuildOfASourceWithNoAccessGivesTheError() async throws {
    let fixture = try await Self.fixture(name: "rebuild-no-access")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let codex = ImportSourceAgent.codex.rawValue

    await #expect(throws: ExternalSessionError.sourceUnreadable(source: codex)) {
      try await host.rebuildExternalSessionIndex(source: codex)
    }
    await #expect(throws: ExternalSessionError.sourceUnreadable(source: "none")) {
      try await host.rebuildExternalSessionIndex(source: "none")
    }
  }

  @Test("the counts of the host count the typed session of the root and of its folder")
  func theCountsCountTheTypedSession() async throws {
    let fixture = try await Self.fixture(name: "counts")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter

    let root = try await host.externalSessionCounts(source: nil, folder: nil)
    let folder = try await host.externalSessionCounts(source: nil, folder: Self.claudeFolder)
    let other = try await host.externalSessionCounts(
      source: nil, folder: URL(fileURLWithPath: "/work/other", isDirectory: true))

    #expect(root.typedCount == 1)
    #expect(root.automatedCount == 0)
    #expect(root.indexState.isComplete)
    #expect(folder.typedCount == 1)
    #expect(other.typedCount == 0)
  }

  @Test("a session with no copy has no earlier copy, and each continue adds one, the oldest first")
  func eachContinueAddsAnEarlierCopy() async throws {
    let fixture = try await Self.fixture(name: "copies")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let query = ExternalSessionQuery(limit: 10)
    let folder = makeResolvedDirectory(label: "\(Self.label)-copies-folder")

    let before = try await host.externalSessions(query)
    let first = try await host.continueExternalSession(
      ExternalSessionContinueRequest(session: Self.session, folder: folder, name: "First"))
    let second = try await host.continueExternalSession(
      ExternalSessionContinueRequest(session: Self.session, folder: folder, name: "Second"))
    let after = try await host.externalSessions(query)

    #expect(before.sessions.first?.continuedSessions == [])
    #expect(
      after.sessions.first?.continuedSessions
        == [
          ExternalSessionContinuation(sessionID: first.id, createdAt: first.createdAt),
          ExternalSessionContinuation(sessionID: second.id, createdAt: second.createdAt),
        ])
  }

  @Test("a new importer reads the earlier copies from the directory")
  func aNewImporterReadsTheEarlierCopies() async throws {
    let fixture = try await Self.fixture(name: "copies-read")
    defer { await fixture.close() }
    let importer = fixture.harness.agent.sessionImporter
    let copy = try await importer.continueExternalSession(
      ExternalSessionContinueRequest(
        session: Self.session, folder: makeResolvedDirectory(label: "\(Self.label)-copies-read-folder")))

    let fresh = ExternalSessionContinuations(directory: fixture.harness.agent.sessionDirectory)
    let copies = await fresh.continuations(of: [Self.session])

    #expect(copies[Self.session] == [ExternalSessionContinuation(sessionID: copy.id, createdAt: copy.createdAt)])
  }

  @Test("the file URL of a session is the root plus the path of the session")
  func theFileURLIsTheRootPlusThePath() async throws {
    let fixture = try await Self.fixture(name: "file-url")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    let roots = await fixture.harness.agent.sessionImporter.index.rootURLs

    let summary = try #require(try await host.externalSessions(ExternalSessionQuery(limit: 10)).sessions.first)
    let root = try #require(roots[.claudeCode])

    #expect(summary.fileURL?.path == root.canonicalPath + "/" + summary.path)
    #expect(FileManager.default.fileExists(atPath: try #require(summary.fileURL).path))
  }

  @Test("the file URL of a session of a root with a symbolic link is in the resolved root")
  func theFileURLOfALinkedRootIsInTheResolvedRoot() async throws {
    let real = try Self.makeClaudeRoot()
    let link = makeResolvedDirectory(label: "\(Self.label)-link").appendingPathComponent(".claude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    let fixture = try await Self.fixture(name: "file-url-link", root: link)
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter

    let summary = try #require(try await host.externalSessions(ExternalSessionQuery(limit: 10)).sessions.first)

    #expect(summary.fileURL?.path == real.canonicalPath + "/" + summary.path)
  }

  @Test("a path that leaves the root, or a source with no root, gives no file URL")
  func aPathOutsideTheRootGivesNoFileURL() throws {
    let root = URL(fileURLWithPath: "/grant/.claude", isDirectory: true)
    let roots: [ImportSourceAgent: URL] = [.claudeCode: root]
    func summary(_ source: ImportSourceAgent, path: String) -> ExternalSessionSummary {
      ExternalSessionSummary(
        source: source.rawValue, sourceID: "id", path: path, size: 1,
        modified: Date(timeIntervalSince1970: 0), state: .read)
    }

    #expect(
      AgentSessionImporter.fileURL(of: summary(.claudeCode, path: "projects/a/b.jsonl"), roots: roots)?.path
        == "/grant/.claude/projects/a/b.jsonl")
    #expect(AgentSessionImporter.fileURL(of: summary(.claudeCode, path: "../outside.jsonl"), roots: roots) == nil)
    #expect(AgentSessionImporter.fileURL(of: summary(.codex, path: "sessions/a.jsonl"), roots: roots) == nil)
  }

  @Test("a changed session of the change stream of the host has its file URL")
  func aChangedSessionHasItsFileURL() async throws {
    let fixture = try await Self.fixture(name: "changes-file-url")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    var changes = host.externalSessionChanges(folder: nil).makeAsyncIterator()
    _ = await changes.next()

    try await host.rebuildExternalSessionIndex(source: ImportSourceAgent.claudeCode.rawValue)
    var changed: ExternalSessionSummary?
    while changed == nil, let change = await changes.next() {
      changed = change.changed.first { $0.id == Self.session }
    }

    #expect(changed?.fileURL != nil)
  }

  @Test(
    "a continue gives the source row with the new copy to a subscriber of its folder and of each folder",
    arguments: [claudeFolder, nil])
  func aContinueGivesTheSourceRowToASubscriber(folder: URL?) async throws {
    let fixture = try await Self.fixture(name: "copy-change-\(folder == nil ? "all" : "folder")")
    defer { await fixture.close() }
    let host: any ExternalSessionHost = fixture.harness.agent.sessionImporter
    var changes = host.externalSessionChanges(folder: folder).makeAsyncIterator()
    _ = await changes.next()

    let copy = try await host.continueExternalSession(
      ExternalSessionContinueRequest(
        session: Self.session,
        folder: makeResolvedDirectory(label: "\(Self.label)-copy-change-folder")))
    var changed: ExternalSessionSummary?
    while changed == nil, let change = await changes.next() {
      changed = change.changed.first { $0.id == Self.session && !$0.continuedSessions.isEmpty }
    }

    #expect(
      changed?.continuedSessions
        == [ExternalSessionContinuation(sessionID: copy.id, createdAt: copy.createdAt)])
    #expect(changed?.fileURL != nil)
  }

  @Test("the lookup of one session gives the row of the page, with its file URL and its copies")
  func theLookupGivesTheRowOfThePage() async throws {
    let fixture = try await Self.fixture(name: "lookup")
    defer { await fixture.close() }
    let importer = fixture.harness.agent.sessionImporter
    let host: any ExternalSessionHost = importer
    _ = try await host.continueExternalSession(
      ExternalSessionContinueRequest(session: Self.session, folder: makeResolvedDirectory(label: "\(Self.label)-lookup-folder")))

    let row = try await host.externalSessions(ExternalSessionQuery(limit: 10)).sessions.first
    let summary = try await importer.externalSession(Self.session)

    #expect(summary != nil)
    #expect(summary == row)
    #expect(summary?.fileURL != nil)
    #expect(summary?.continuedSessions.count == 1)
  }

  @Test("the lookup of an unknown session gives nil, and of a source with no access an error")
  func theLookupOfAnUnknownSession() async throws {
    let fixture = try await Self.fixture(name: "lookup-unknown")
    defer { await fixture.close() }
    let importer = fixture.harness.agent.sessionImporter
    let codex = ExternalSessionID(source: ImportSourceAgent.codex.rawValue, sourceID: Self.claudeID)

    let unknown = try await importer.externalSession(
      ExternalSessionID(source: ImportSourceAgent.claudeCode.rawValue, sourceID: "none"))

    #expect(unknown == nil)
    await #expect(throws: ExternalSessionError.sourceUnreadable(source: codex.source)) {
      _ = try await importer.externalSession(codex)
    }
  }
}
