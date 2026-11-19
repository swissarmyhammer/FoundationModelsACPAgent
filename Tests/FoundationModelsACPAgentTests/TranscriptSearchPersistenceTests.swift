import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsMetadataRegistry
import FoundationModelsMultitool
import Synchronization
import Testing

@testable import FoundationModelsACPAgent

/// The persistence of the transcript search index (D207, ^y7nx1g3): the searcher keeps its
/// catalog and its vectors in the folder of the index, a new index over the same folder starts
/// from the stored catalog with no embed, and each change gives only the changed items.
@Suite struct TranscriptSearchPersistenceTests {
  // MARK: - Constants

  /// The prefix that names the throwaway folders of each test.
  private static let label = "TranscriptSearchPersistenceTests"

  /// The session that the tests index.
  private static let sessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YB")

  /// A second session.
  private static let otherSessionId = SessionId(rawValue: "01KAXN6R4M8ZJ0C2W3Q5T7V9YC")

  /// The id of the embedding model of the first index.
  private static let modelID = "fake-embedding-1"

  /// The id of another embedding model.
  private static let otherModelID = "fake-embedding-2"

  /// A word that only the agent message of ``sessionId`` holds.
  private static let chunkWord = "quokka"

  /// The working folder of the sessions.
  private static let folder = URL(fileURLWithPath: "/projects/zoo", isDirectory: true)

  /// The time that a test waits for the change stream.
  private static let readTimeout = Duration.seconds(90)

  /// The time zone of the parse of a query.
  private static let timeZone = TimeZone(identifier: "UTC") ?? .current

  /// The most sessions of a page of the search.
  private static let pageLimit = 10

  /// The facts of ``sessionId``.
  private static let metadata = TranscriptSessionMetadata(
    name: "Zebra research", slug: "zebra-research", tags: [], folder: folder, agentName: nil,
    recap: nil, lastSummary: nil)

  /// The facts of ``otherSessionId``.
  private static let otherMetadata = TranscriptSessionMetadata(
    name: "Kitchen plans", slug: "kitchen-plans", tags: [], folder: folder, agentName: nil,
    recap: nil, lastSummary: nil)

  /// The chunks of ``sessionId``.
  private static let chunks = chunks(answer: "The \(chunkWord) lives on an island.")

  /// The chunks of ``otherSessionId``.
  private static let otherChunks = chunks(answer: "The blue tiles fit the wall.")

  /// The number of items of the stored catalog: a session item and the chunk items of each
  /// session.
  private static let storedItemCount = 2 + chunks.count + otherChunks.count

  // MARK: - Fixtures

  /// The chunks of a transcript of one user message and one agent message.
  ///
  /// - Parameter answer: The text of the agent message.
  /// - Returns: The chunks.
  private static func chunks(answer: String) -> [SessionSearchChunk] {
    SessionMergeEngine(replaying: [
      .userMessage(
        UserMessage(
          messageId: MessageId(rawValue: "user-1"),
          content: .value([.text(TextContent(text: "Where do they live?"))]))),
      .agentMessageChunk(
        ContentChunk(
          content: .text(TextContent(text: answer)), messageId: MessageId(rawValue: "agent-1"))),
    ]).searchChunks
  }

  /// An index over a folder that did not load its stored catalog: the init only keeps its
  /// arguments.
  ///
  /// - Parameters:
  ///   - folder: The folder of the index.
  ///   - embedder: The embedder of the index.
  ///   - modelID: The id of the embedding model.
  ///   - readableFolder: Tells whether the process can read a folder now.
  ///   - diagnostics: Records each diagnostic of the registry.
  /// - Returns: The index.
  private static func makeUnloadedIndex(
    in folder: URL, embedder: CountingEmbedding = CountingEmbedding(), modelID: String = modelID,
    readableFolder: @escaping @Sendable (URL) -> Bool = { _ in true },
    diagnostics: DiagnosticRecorder = DiagnosticRecorder()
  ) -> TranscriptSearchIndex {
    TranscriptSearchIndex(
      folder: folder, embedder: embedder, modelID: modelID, readableFolder: readableFolder,
      onDiagnostic: { diagnostics.record($0) })
  }

  /// An index over a folder that loaded its stored catalog, as the host makes it.
  ///
  /// - Parameters:
  ///   - folder: The folder of the index.
  ///   - embedder: The embedder of the index.
  ///   - modelID: The id of the embedding model.
  ///   - readableFolder: Tells whether the process can read a folder now.
  ///   - diagnostics: Records each diagnostic of the registry.
  /// - Returns: The index.
  private static func makeIndex(
    in folder: URL, embedder: CountingEmbedding = CountingEmbedding(), modelID: String = modelID,
    readableFolder: @escaping @Sendable (URL) -> Bool = { _ in true },
    diagnostics: DiagnosticRecorder = DiagnosticRecorder()
  ) async -> TranscriptSearchIndex {
    let index = makeUnloadedIndex(
      in: folder, embedder: embedder, modelID: modelID, readableFolder: readableFolder,
      diagnostics: diagnostics)
    await index.load()
    return index
  }

  /// The items of ``sessionId`` in the stored catalog: the session item, then the chunk items.
  private static var storedItems: [TranscriptSearchItem] {
    [TranscriptSearchItem(session: sessionId, metadata: metadata)]
      + chunks.map { TranscriptSearchItem(chunk: $0, session: sessionId) }
  }

  /// A new folder that holds a stored catalog of the old form of the item ids (before
  /// ^8qsp7hb): the items of ``sessionId``, with the session id as the id of the session item,
  /// under the key of the embedding model alone.
  ///
  /// - Parameter label: The label of the folder.
  /// - Returns: The folder.
  private static func makeOldFormFolder(label: String) async -> URL {
    let folder = makeResolvedDirectory(label: "\(Self.label)-\(label)")
    let searcher = await MetadataSearcher<OldFormTranscriptSearchItem>(
      persistence: CatalogPersistence(folder: folder, embeddingModelID: modelID),
      mode: .retrieval, embedder: CountingEmbedding())
    await searcher.update(
      upserting: storedItems.map(OldFormTranscriptSearchItem.init), removing: [])
    await searcher.waitForSaves()
    return folder
  }

  /// A new folder that holds the stored catalog of an index with the two sessions in it.
  ///
  /// - Parameter label: The label of the folder.
  /// - Returns: The folder.
  private static func makeStoredFolder(label: String) async -> URL {
    let folder = makeResolvedDirectory(label: "\(Self.label)-\(label)")
    let index = await makeIndex(in: folder)
    await index.index(session: sessionId, chunks: chunks, metadata: metadata)
    await index.index(session: otherSessionId, chunks: otherChunks, metadata: otherMetadata)
    await index.waitForSaves()
    return folder
  }

  /// Reads the first change of a new stream of an index while `request` runs.
  ///
  /// - Parameters:
  ///   - index: The index.
  ///   - request: The steps that change the index.
  /// - Returns: The first change, or `nil` when none came before ``readTimeout``.
  /// - Throws: The error of `request`.
  private static func firstChange(
    of index: TranscriptSearchIndex, whileRunning request: () async throws -> Void
  ) async throws -> TranscriptSearchChange? {
    let stream = index.changes()
    return try await TimedRead.value(
      of: { await stream.first { _ in true } }, timeout: readTimeout, whileRunning: request
    ) ?? nil
  }

  /// Reconciles the working folder of the sessions with an empty recording root, in which no
  /// session has a history file, and waits until the index applied the reconcile.
  ///
  /// - Parameters:
  ///   - index: The index.
  ///   - label: The label of the empty recording root.
  private static func reconcileWithNoHistory(_ index: TranscriptSearchIndex, label: String) async {
    let root = makeResolvedDirectory(label: "\(Self.label)-\(label)-root")
    let updates = TranscriptSearchUpdates(index: index) { _ in nil }
    await updates.reconcile(folders: [folder], recordingRoot: { _ in root })
    await updates.waitUntilApplied()
  }

  // MARK: - A new index over the same folder

  /// A new index over the folder of a stored catalog finds a word of a chunk, and embeds only
  /// the query: it embeds no item again.
  @Test(.timeLimit(.minutes(3))) func aNewIndexOverTheSameFolderSearchesWithNoEmbed() async throws {
    let folder = await Self.makeStoredFolder(label: "no-embed")
    let embedder = CountingEmbedding()
    let index = await Self.makeIndex(in: folder, embedder: embedder)

    let firstID = try await index.matches(for: Self.chunkWord).first?.id

    #expect(
      [firstID, String(embedder.embeddedTextCount)] == ["\(Self.sessionId.rawValue)/1", "1"])
  }

  /// A new index over the folder of a stored catalog holds the items of each stored session.
  @Test(.timeLimit(.minutes(3))) func aNewIndexHoldsTheStoredSessions() async throws {
    let folder = await Self.makeStoredFolder(label: "restore")

    let index = await Self.makeIndex(in: folder)

    #expect(await index.items(of: Self.sessionId) == Self.storedItems)
  }

  // MARK: - The explicit load

  /// The init reads nothing from the folder: a stored catalog of another embedding model gives
  /// no drop before the load.
  @Test(.timeLimit(.minutes(3))) func theInitReadsNoStoredCatalog() async {
    let folder = await Self.makeStoredFolder(label: "init-reads-nothing")
    let diagnostics = DiagnosticRecorder()

    _ = Self.makeUnloadedIndex(in: folder, modelID: Self.otherModelID, diagnostics: diagnostics)

    #expect(diagnostics.all.isEmpty)
  }

  /// Two loads at the same time read the stored catalog one time.
  @Test(.timeLimit(.minutes(3))) func twoLoadsReadTheStoredCatalogOneTime() async {
    let folder = await Self.makeStoredFolder(label: "two-loads")
    let diagnostics = DiagnosticRecorder()
    let index = Self.makeUnloadedIndex(
      in: folder, modelID: Self.otherModelID, diagnostics: diagnostics)

    async let first: Void = index.load()
    async let second: Void = index.load()
    _ = await (first, second)

    #expect(
      diagnostics.all.filter { $0 == .storedCatalogDropped(reason: .embeddingModel) }.count == 1)
  }

  /// A read that the host makes before the load waits for the load: it gives the stored items.
  @Test(.timeLimit(.minutes(3))) func aReadBeforeTheLoadGivesTheStoredItems() async {
    let folder = await Self.makeStoredFolder(label: "read-before-load")
    let index = Self.makeUnloadedIndex(in: folder)

    #expect(await index.items(of: Self.sessionId) == Self.storedItems)
  }

  /// A change that the host makes before the load waits for the load: the stored items of the
  /// other session stay.
  @Test(.timeLimit(.minutes(3))) func aChangeBeforeTheLoadKeepsTheStoredItems() async {
    let folder = await Self.makeStoredFolder(label: "change-before-load")
    let index = Self.makeUnloadedIndex(in: folder)

    await index.index(
      session: Self.otherSessionId, chunks: Self.chunks(answer: "New tiles."),
      metadata: Self.otherMetadata)

    #expect(await index.items(of: Self.sessionId) == Self.storedItems)
  }

  /// A wait for the saves before the load reads nothing from the folder.
  @Test(.timeLimit(.minutes(3))) func aWaitForTheSavesBeforeTheLoadReadsNothing() async {
    let folder = await Self.makeStoredFolder(label: "wait-before-load")
    let diagnostics = DiagnosticRecorder()
    let index = Self.makeUnloadedIndex(
      in: folder, modelID: Self.otherModelID, diagnostics: diagnostics)

    await index.waitForSaves()

    #expect(diagnostics.all.isEmpty)
  }

  /// A new index gives the stored content of a session again as no change: the stream gives the
  /// change of the session that changed first.
  @Test(.timeLimit(.minutes(3))) func theStoredContentOfASessionIsNoChange() async throws {
    let folder = await Self.makeStoredFolder(label: "no-change")
    let index = await Self.makeIndex(in: folder)

    let change = try await Self.firstChange(of: index) {
      await index.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
      await index.index(
        session: Self.otherSessionId, chunks: Self.chunks(answer: "New tiles."),
        metadata: Self.otherMetadata)
    }

    #expect(
      change
        == .indexed(
          session: Self.otherSessionId,
          turns: TranscriptSearchTurn.turns(
            of: Self.otherSessionId, chunks: Self.chunks(answer: "New tiles."))))
  }

  // MARK: - The embedding model

  /// A new index with another embedding model drops the stored catalog.
  @Test(.timeLimit(.minutes(3))) func anotherEmbeddingModelDropsTheStoredCatalog() async throws {
    let folder = await Self.makeStoredFolder(label: "model-drop")
    let diagnostics = DiagnosticRecorder()

    let index = await Self.makeIndex(
      in: folder, modelID: Self.otherModelID, diagnostics: diagnostics)

    #expect(
      (await index.items(of: Self.sessionId)).isEmpty
        && diagnostics.all.contains(.storedCatalogDropped(reason: .embeddingModel)))
  }

  /// After a drop for another embedding model, the next index of a session builds the stored
  /// catalog again with the new model: a later index finds the session with no embed of an item.
  @Test(.timeLimit(.minutes(3))) func theNextIndexBuildsTheDroppedCatalogAgain() async throws {
    let folder = await Self.makeStoredFolder(label: "model-rebuild")
    let rebuilt = await Self.makeIndex(in: folder, modelID: Self.otherModelID)
    await rebuilt.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    await rebuilt.waitForSaves()
    let embedder = CountingEmbedding()
    let index = await Self.makeIndex(in: folder, embedder: embedder, modelID: Self.otherModelID)

    let firstID = try await index.matches(for: Self.chunkWord).first?.id

    #expect(
      [firstID, String(embedder.embeddedTextCount)] == ["\(Self.sessionId.rawValue)/1", "1"])
  }

  // MARK: - The form of the item ids

  /// A stored catalog of the old form of the item ids is dropped at the load: the new index
  /// holds no item of it (^8qsp7hb).
  @Test(.timeLimit(.minutes(3))) func anOldFormCatalogIsDropped() async throws {
    let folder = await Self.makeOldFormFolder(label: "old-form-drop")

    let index = await Self.makeIndex(in: folder)

    #expect(await index.items(of: Self.sessionId).isEmpty)
  }

  /// After the drop of a stored catalog of the old form, the next index of a session builds the
  /// stored catalog again in the new form: a later index holds the items of the new form.
  @Test(.timeLimit(.minutes(3))) func theNextIndexBuildsAnOldFormCatalogAgain() async throws {
    let folder = await Self.makeOldFormFolder(label: "old-form-rebuild")
    let rebuilt = await Self.makeIndex(in: folder)
    await rebuilt.index(session: Self.sessionId, chunks: Self.chunks, metadata: Self.metadata)
    await rebuilt.waitForSaves()

    let index = await Self.makeIndex(in: folder)

    #expect(await index.items(of: Self.sessionId) == Self.storedItems)
  }

  // MARK: - The update of some items

  /// A new index of one session keeps the stored items of the other session.
  @Test(.timeLimit(.minutes(3))) func anUpsertKeepsTheOtherItems() async throws {
    let folder = await Self.makeStoredFolder(label: "upsert")
    let index = await Self.makeIndex(in: folder)
    await index.index(
      session: Self.sessionId, chunks: Self.chunks(answer: "A new answer."),
      metadata: Self.metadata)
    await index.waitForSaves()

    let restored = await Self.makeIndex(in: folder)

    #expect(
      await restored.items(of: Self.otherSessionId)
        == [TranscriptSearchItem(session: Self.otherSessionId, metadata: Self.otherMetadata)]
        + Self.otherChunks.map { TranscriptSearchItem(chunk: $0, session: Self.otherSessionId) })
  }

  /// A delete removes only the ids of the deleted session from the stored catalog.
  @Test(.timeLimit(.minutes(3))) func aDeleteRemovesOnlyTheIdsOfThatSession() async throws {
    let folder = await Self.makeStoredFolder(label: "delete")
    let index = await Self.makeIndex(in: folder)
    await index.remove(session: Self.sessionId)
    await index.waitForSaves()

    let restored = await Self.makeIndex(in: folder)

    #expect(
      await restored.catalog.map(\.id)
        == [TranscriptSearchItem(session: Self.otherSessionId, metadata: Self.otherMetadata).id]
        + Self.otherChunks.indices.map { "\(Self.otherSessionId.rawValue)/\($0)" })
  }

  // MARK: - The reconcile from the stored catalog

  /// The reconcile removes the stored items of a session whose history file was deleted while
  /// the agent was off.
  @Test(.timeLimit(.minutes(3))) func theReconcileRemovesASessionDeletedWhileTheAgentWasOff()
    async throws
  {
    let folder = await Self.makeStoredFolder(label: "deleted-off")
    let index = await Self.makeIndex(in: folder)
    let heldAtStart = await index.catalog.count

    await Self.reconcileWithNoHistory(index, label: "deleted-off")

    #expect([heldAtStart, await index.catalog.count] == [Self.storedItemCount, 0])
  }

  /// The stored sessions of a folder that the process cannot read stay after the reconcile, and
  /// give their turns.
  @Test(.timeLimit(.minutes(3))) func theStoredSessionsOfAnUnreadableFolderStay() async throws {
    let folder = await Self.makeStoredFolder(label: "unreadable")
    let index = await Self.makeIndex(in: folder, readableFolder: { _ in false })

    await Self.reconcileWithNoHistory(index, label: "unreadable")

    #expect(
      Set(await index.allTurns().map(\.sessionId)) == [Self.sessionId, Self.otherSessionId])
  }

  /// A query with only tokens finds the chunks of the stored sessions.
  @Test(.timeLimit(.minutes(3))) func aTokenOnlyQueryFindsTheStoredSessions() async throws {
    let folder = await Self.makeStoredFolder(label: "token-only")
    let index = await Self.makeIndex(in: folder, readableFolder: { _ in false })

    let visible = [Self.sessionId, Self.otherSessionId].reduce(
      into: [SessionId: TranscriptSearchVisibleSession]()
    ) { visible, session in
      visible[session] = TranscriptSearchVisibleSession(folder: Self.folder, isArchived: false)
    }

    let page = try await index.search(
      SessionSearchRequest(
        query: try SessionSearchQuery(parsing: "from:agent", timeZone: Self.timeZone),
        sessions: nil, includeArchived: false, preferredFolder: nil, session: nil,
        limit: Self.pageLimit, cursor: nil),
      visibleSessions: visible)

    #expect(
      Set(page.sessions.map(\.session))
        == [try Self.sessionId.ulid(), try Self.otherSessionId.ulid()])
  }
}

/// Records the diagnostics of the registry for a test.
final class DiagnosticRecorder: Sendable {
  /// The diagnostics, in their order.
  private let diagnostics = Mutex<[MetadataDiagnostic]>([])

  /// Each recorded diagnostic, in its order.
  var all: [MetadataDiagnostic] {
    diagnostics.withLock { $0 }
  }

  /// Records one diagnostic.
  ///
  /// - Parameter diagnostic: The diagnostic.
  func record(_ diagnostic: MetadataDiagnostic) {
    diagnostics.withLock { $0.append(diagnostic) }
  }
}

/// An item of the transcript search with the old form of the ids (before ^8qsp7hb): the session
/// id is the id of the session item. The coded form is the coded form of the item.
private struct OldFormTranscriptSearchItem: SearchableMetadata, Codable {
  /// The item.
  let item: TranscriptSearchItem

  /// The id of the old form: the session id for a session item, and the id of the item for a
  /// chunk item.
  var id: String {
    guard case .session = item.content else {
      return item.id
    }
    return item.sessionId.rawValue
  }

  /// Makes the old form of an item.
  ///
  /// - Parameter item: The item.
  init(_ item: TranscriptSearchItem) {
    self.item = item
  }

  /// Decodes the item.
  ///
  /// - Parameter decoder: The decoder.
  /// - Throws: The error of the decode of the item.
  init(from decoder: any Decoder) throws {
    item = try TranscriptSearchItem(from: decoder)
  }

  /// Encodes the item.
  ///
  /// - Parameter encoder: The encoder.
  /// - Throws: The error of the encode of the item.
  func encode(to encoder: any Encoder) throws {
    try item.encode(to: encoder)
  }

  /// The block of the item.
  ///
  /// - Returns: The block.
  func renderBlock() -> String {
    item.renderBlock()
  }
}
