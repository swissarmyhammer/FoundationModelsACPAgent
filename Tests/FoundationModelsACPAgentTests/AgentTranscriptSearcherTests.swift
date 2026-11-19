import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import FoundationModelsMultitool
import FoundationModelsRouter
import GraphQL
import Testing

@testable import FoundationModelsACPAgent

/// The searcher of the transcripts that the agent gives to the `sessions` tool and endpoint
/// (D207): it searches the index of the agent over the sessions that the session directory
/// shows. The suite trait closes each harness of a test whose body throws.
@Suite(.closesHarnesses, .timeLimit(.minutes(2))) struct AgentTranscriptSearcherTests {
  // MARK: - Types

  /// One result of the `searchSessions` field: the short id of its session and the snippets of
  /// its hits.
  private struct FieldResult: Equatable {
    /// The short id of the session.
    let shortID: String

    /// The snippets of the hits.
    let snippets: [String]
  }

  /// One page of the `searchSessions` field.
  private struct FieldPage {
    /// The results, in order.
    let results: [FieldResult]

    /// The cursor of the next page, or `nil`.
    let nextCursor: String?
  }

  // MARK: - Constants

  /// The directory label of the suite.
  private static let label = "AgentTranscriptSearcherTests"

  /// The word of the indexed chunks.
  private static let word = "quokka"

  /// A session that the session directory does not know.
  private static let unknownSession = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YZ")

  /// The most sessions of a page of the tests.
  private static let pageLimit = 10

  /// The text of the prompt that makes the scripted model call the `sessions` tool.
  private static let toolMarker = "SEARCH-BY-TOOL"

  /// The name of the `sessions` tool.
  private static let sessionsName = "sessions"

  /// The end of the text of the indexed chunk of the first session, after the matched word.
  private static let snippetTail = "lives on an island."

  /// The end of the text of the indexed chunk of the second session, after the matched word.
  private static let secondSnippetTail = "eats the leaves."

  /// The query of one page of the `searchSessions` field.
  private static let fieldQuery = """
    query($query: String!, $after: String) {
      searchSessions(query: $query, first: FIRST, after: $after) {
        results { session { shortId } hits { snippet } }
        nextCursor
      }
    }
    """

  /// The text in ``fieldQuery`` that the size of the page replaces.
  private static let firstPlaceholder = "FIRST"

  /// The number of sessions of ``searchFixture(name:)`` whose chunks hold ``word``.
  private static let searchedSessionCount = 2

  /// The tag that ``settle(_:on:)`` adds to a session of the directory.
  private static let settledTag = "settled"

  // MARK: - Helpers

  /// The text of the indexed chunk of ``indexWord(of:on:folder:tail:)``.
  ///
  /// - Parameter tail: The text of the message after the word.
  /// - Returns: The text.
  private static func chunkText(tail: String) -> String {
    "The \(word) \(tail)"
  }

  /// Indexes one agent message with ``word`` for a session.
  ///
  /// - Parameters:
  ///   - session: The session.
  ///   - agent: The agent whose index gets the chunk.
  ///   - folder: The folder of the session.
  ///   - tail: The text of the message after the word.
  private static func indexWord(
    of session: SessionId, on agent: RoutedACPAgent, folder: URL, tail: String
  ) async {
    let text = chunkText(tail: tail)
    await agent.transcriptSearchIndex.index(
      session: session,
      chunks: [
        SessionSearchChunk(
          turn: 0, ordinal: 0, kind: .agent, author: nil, date: nil, title: "", text: text,
          entries: [
            SessionSearchChunk.EntryRange(
              id: .agentMessage(MessageId(rawValue: "agent-1")), range: 0..<text.count)
          ])
      ],
      metadata: TranscriptSessionMetadata(
        name: "", slug: "", tags: [], folder: folder, agentName: nil, recap: nil,
        lastSummary: nil))
  }

  /// Indexes ``word`` for a set of sessions with no change of the background updates of the
  /// agent to come (^fr3d9xk).
  ///
  /// The agent changes its index in the background. The reconcile at launch removes the items
  /// of each session of the fixture folder, because no session of the fixture has a history
  /// file. An event of the session directory (a `started`, a `factsChanged` with the name of the
  /// session) replaces the session item. Thus the call first waits until the reconcile at launch
  /// is applied, and then indexes the chunks. It then settles each session that the directory
  /// knows (``settle(_:on:)``).
  ///
  /// - Parameters:
  ///   - tails: The text after the word in the chunk of each session.
  ///   - agent: The agent whose index gets the chunks.
  ///   - folder: The folder of the sessions.
  /// - Throws: The error of the directory, or the failure of a session that does not settle.
  private static func indexSettled(
    _ tails: KeyValuePairs<SessionId, String>, on agent: RoutedACPAgent, folder: URL
  ) async throws {
    await agent.transcriptSearchUpdates.waitUntilApplied()
    for (session, tail) in tails {
      await indexWord(of: session, on: agent, folder: folder, tail: tail)
    }
    for (session, _) in tails {
      if try await agent.sessionDirectory.summary(of: try session.ulid()) != nil {
        try await settle(session, on: agent)
      }
    }
  }

  /// Waits until the index of the agent applied each event of the session directory for one
  /// session. The call adds ``settledTag`` to the session, and waits until the index holds the
  /// session item of the tagged session. The events of the directory come to the index in
  /// order, so each earlier event of the session is applied too.
  ///
  /// - Parameters:
  ///   - session: A session of the directory that the index holds.
  ///   - agent: The agent.
  /// - Throws: The error of the directory, or the failure of an index that does not apply the
  ///   tag.
  private static func settle(_ session: SessionId, on agent: RoutedACPAgent) async throws {
    let tagged = try await agent.sessionDirectory.addTags([settledTag], to: try session.ulid())
    let expected = TranscriptSearchItem(
      session: session, metadata: TranscriptSessionMetadata(summary: tagged))
    let index = agent.transcriptSearchIndex
    try await pollIndexUntil {
      await index.items(of: session).first == expected
    }
    try #require(await index.items(of: session).first == expected)
  }

  /// The request of a search of ``word`` in each visible session.
  ///
  /// - Returns: The request.
  /// - Throws: The refusal of a query that does not parse.
  private static func wordRequest() throws -> SessionSearchRequest {
    SessionSearchRequest(
      query: try SessionSearchQuery(parsing: word), sessions: nil, includeArchived: false,
      preferredFolder: nil, session: nil, limit: pageLimit, cursor: nil)
  }

  /// A scripted agent whose model calls the `sessions` tool with a `search sessions` of ``word``
  /// on the prompt ``toolMarker``, with two sessions whose chunks hold ``word``.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The fixture.
  /// - Throws: The error of the fixture, of the second session or of the write of the
  ///   arguments.
  private static func searchFixture(name: String) async throws -> ScriptedPromptFixture {
    let argumentsPath = makeResolvedDirectory(label: "\(label)-\(name)-files")
      .appendingPathComponent("search.json").path
    let fixture = try await ScriptedPromptFixture.make(
      script: [
        .onPrompt(
          containing: toolMarker,
          play: [.toolCallFromFile(name: sessionsName, path: argumentsPath), .endPass]),
        .endPass,
      ],
      label: "\(label)-\(name)")
    let agent = fixture.harness.agent
    let second = try await fixture.harness.connection.newSession(
      AgentClientHarness.makeNewSessionRequest(cwd: fixture.cwd)
    ).sessionId
    try await indexSettled(
      [fixture.sessionId: snippetTail, second: secondSnippetTail], on: agent, folder: fixture.cwd)
    try #"{"op":"search sessions","query":"\#(word)"}"#
      .write(toFile: argumentsPath, atomically: true, encoding: .utf8)
    return fixture
  }

  /// The answer of the `search sessions` call of the scripted model.
  ///
  /// - Parameter fixture: The fixture of ``searchFixture(name:)``.
  /// - Returns: The text of the tool call.
  /// - Throws: The error of the prompt.
  private static func toolAnswer(of fixture: ScriptedPromptFixture) async throws -> String {
    let run = try await ScriptedPromptFixture.runPrompt(on: fixture, text: toolMarker)
    return SkillsLibraryTests.toolCallText(in: run.updates)
  }

  /// One page of the `searchSessions` field of the `sessions` endpoint of the directory of an
  /// agent, for ``word``.
  ///
  /// - Parameters:
  ///   - agent: The agent.
  ///   - first: The most sessions of the page.
  ///   - after: The cursor of the page, or `nil`.
  /// - Returns: The page.
  /// - Throws: The failure of a reply that has no page.
  private static func fieldPage(of agent: RoutedACPAgent, first: Int, after: String?) async throws
    -> FieldPage
  {
    await agent.transcriptSearchUpdates.waitUntilApplied()
    var variables: [String: Map] = ["query": .string(word)]
    variables["after"] = after.map(Map.string)
    let reply = try await SessionsGraph.endpoint(of: agent.sessionDirectory).execute(
      query: fieldQuery.replacingOccurrences(of: firstPlaceholder, with: String(first)),
      variables: variables, operationName: nil, viewer: nil)
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    let data = try #require(object["data"] as? [String: Any], "\(reply)")
    let connection = try #require(data["searchSessions"] as? [String: Any], "\(reply)")
    let results = try #require(connection["results"] as? [[String: Any]], "\(reply)")
    return FieldPage(
      results: try results.map { try fieldResult(of: $0, reply: reply) },
      nextCursor: connection["nextCursor"] as? String)
  }

  /// One result of the `searchSessions` field.
  ///
  /// - Parameters:
  ///   - object: The JSON object of the result.
  ///   - reply: The whole reply, for the failure.
  /// - Returns: The result.
  /// - Throws: The failure of a result that has no session or no hits.
  private static func fieldResult(of object: [String: Any], reply: String) throws -> FieldResult {
    let session = try #require(object["session"] as? [String: Any], "\(reply)")
    let hits = try #require(object["hits"] as? [[String: Any]], "\(reply)")
    return FieldResult(
      shortID: try #require(session["shortId"] as? String, "\(reply)"),
      snippets: hits.compactMap { $0["snippet"] as? String })
  }

  // MARK: - The searcher

  /// The searcher finds a word of a session that the directory shows.
  @Test func theSearcherFindsASessionOfTheDirectory() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-found")
    let agent = fixture.harness.agent
    try await Self.indexSettled(
      [fixture.sessionId: Self.snippetTail], on: agent, folder: fixture.cwd)
    await agent.transcriptSearchUpdates.waitUntilApplied()

    let page = try await AgentTranscriptSearcher(agent: agent).search(Self.wordRequest())
    await fixture.close()

    #expect(page.sessions.map(\.session) == [try fixture.sessionId.ulid()])
  }

  /// The searcher gives no session that the directory does not know: of the two sessions whose
  /// chunks hold the word, it gives only the session of the directory.
  @Test func theSearcherLeavesOutASessionThatTheDirectoryDoesNotKnow() async throws {
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(Self.label)-unknown")
    let agent = fixture.harness.agent
    try await Self.indexSettled(
      [Self.unknownSession: Self.snippetTail, fixture.sessionId: Self.snippetTail], on: agent,
      folder: fixture.cwd)
    await agent.transcriptSearchUpdates.waitUntilApplied()

    let page = try await AgentTranscriptSearcher(agent: agent).search(Self.wordRequest())
    await fixture.close()

    #expect(page.sessions.map(\.session) == [try fixture.sessionId.ulid()])
  }

  // MARK: - The tool and the endpoint

  /// The `search sessions` operation of the `sessions` tool of a session searches with the
  /// searcher of the agent: its answer holds the snippet of an indexed chunk.
  @Test func theSessionsToolSearchesWithTheSearcherOfTheAgent() async throws {
    let fixture = try await Self.searchFixture(name: "tool")
    defer { await fixture.close() }

    let answer = try await Self.toolAnswer(of: fixture)

    #expect(answer.contains(Self.snippetTail))
  }

  /// The `searchSessions` field of the `sessions` endpoint gives the sessions and the snippets
  /// that the `search sessions` operation of the tool gives.
  ///
  /// The test reads the field before the prompt. The end of the prompt writes the history of the
  /// turn, and the index then gets the chunks of the turn in a task of its own. A field that the
  /// test reads after the prompt can thus see more chunks than the tool saw.
  @Test func theSearchSessionsFieldGivesTheSessionsAndHitsOfTheTool() async throws {
    let fixture = try await Self.searchFixture(name: "field")
    defer { await fixture.close() }
    let page = try await Self.fieldPage(
      of: fixture.harness.agent, first: Self.pageLimit, after: nil)

    let answer = try await Self.toolAnswer(of: fixture)

    let snippets = Set(page.results.flatMap(\.snippets))
    let marks = page.results.map { "@\($0.shortID)" } + snippets.filter { !$0.isEmpty }
    #expect(page.results.count == Self.searchedSessionCount)
    #expect(
      snippets.isSuperset(of: [
        Self.chunkText(tail: Self.snippetTail), Self.chunkText(tail: Self.secondSnippetTail),
      ]))
    #expect(marks.allSatisfy { answer.contains($0) }, "\(answer)")
  }

  /// The `after` cursor of the `searchSessions` field gives the next page: the pages of one
  /// session give the sessions of one large page, in the same order.
  @Test func theAfterCursorOfTheFieldGivesTheNextPage() async throws {
    let fixture = try await Self.searchFixture(name: "field-cursor")
    defer { await fixture.close() }
    let agent = fixture.harness.agent
    let whole = try await Self.fieldPage(of: agent, first: Self.pageLimit, after: nil)

    let first = try await Self.fieldPage(of: agent, first: 1, after: nil)
    let cursor = try #require(first.nextCursor)
    let second = try await Self.fieldPage(of: agent, first: 1, after: cursor)

    #expect(whole.results.count == Self.searchedSessionCount)
    #expect(second.nextCursor == nil)
    #expect(first.results + second.results == whole.results)
  }
}
