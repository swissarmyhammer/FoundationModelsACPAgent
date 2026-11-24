import ACPImport
import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing

@testable import FoundationModelsACPAgent

/// The external sessions part of the content catalog of a host (D214, part 5): the typed
/// sessions of each source in the state `read`, its stamps, and a change stream.
@Suite(.closesHarnesses) struct ExternalContentCatalogTests {
  /// The label of the folders of the suite.
  private static let label = "ExternalContentCatalogTests"

  /// The source id of the Claude Code session of the root.
  private static let claudeID = "7c1e0000-0000-4000-8000-000000000005"

  /// The working folder of the session.
  private static let folder = URL(fileURLWithPath: "/work/zoo", isDirectory: true)

  /// The id of the session.
  private static let session = ExternalSessionID(
    source: ImportSourceAgent.claudeCode.rawValue, sourceID: claudeID)

  /// An agent over a Claude Code root with one typed session, with its index idle.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The fixture and the root.
  /// - Throws: The error of a write or of the fixture.
  private static func makeFixture(_ name: String) async throws -> (ScriptedPromptFixture, URL) {
    let root = makeResolvedDirectory(label: "\(label)-\(name)")
      .appendingPathComponent(".claude", isDirectory: true)
    try ImportSessionFiles.writeClaudeCode(
      id: claudeID, folder: folder, withAnswer: true, in: root)
    let fixture = try await ScriptedPromptFixture.make(
      script: [.endPass], label: "\(label)-\(name)", importRoots: [.claudeCode: root])
    await fixture.harness.agent.sessionImporter.index.waitUntilIdle()
    return (fixture, root)
  }

  /// Reads the changes of `stream` until one satisfies `matches`.
  ///
  /// - Parameters:
  ///   - stream: The stream.
  ///   - matches: Tells whether a change is the one wanted.
  /// - Returns: The change, or `nil` when the stream ends first.
  private static func firstChange(
    of stream: AsyncStream<ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>>,
    where matches: (ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>) -> Bool
  ) async -> ContentCatalogChange<ImportSourceAgent, ExternalSessionContentRecord>? {
    for await change in stream where matches(change) {
      return change
    }
    return nil
  }

  /// A typed session of a root gives a record with its facts, and its source has a stamp.
  @Test func aTypedSessionGivesARecord() async throws {
    let (fixture, _) = try await Self.makeFixture("typed")
    let catalog = fixture.harness.agent.contentCatalog.externalSessions

    let record = try #require(await catalog.record(Self.session))

    #expect(record.cwd?.standardizedFileURL.path == Self.folder.path)
    #expect(record.firstPrompt == ImportSessionFiles.claudeCodeQuestion)
    #expect(await catalog.records(of: .claudeCode) == [record])
    #expect(await catalog.stamps()[.claudeCode] != nil)
    await fixture.close()
  }

  /// An entry that changes from typed to automated gives "this id went away", and it has no
  /// record.
  @Test func anEntryThatBecomesAutomatedGoesAway() async throws {
    let (fixture, root) = try await Self.makeFixture("automated")
    let agent = fixture.harness.agent
    let changes = agent.contentCatalog.externalSessions.changes()
    try ImportSessionFiles.writeClaudeCode(
      id: Self.claudeID, folder: Self.folder, withAnswer: true, entrypoint: "sdk-cli", in: root)

    try await agent.sessionImporter.rebuildExternalSessionIndex(
      source: ImportSourceAgent.claudeCode.rawValue)

    let change = await Self.firstChange(of: changes) {
      guard case .removed(.claudeCode, let ids) = $0 else { return false }
      return ids.contains(Self.session)
    }
    #expect(change != nil)
    #expect(await agent.contentCatalog.externalSessions.record(Self.session) == nil)
    await fixture.close()
  }

  /// Remove Access (no root of the source) gives "this domain went away".
  @Test func removeAccessGivesTheRemovalOfTheDomain() async throws {
    let (fixture, _) = try await Self.makeFixture("remove-access")
    let agent = fixture.harness.agent
    let changes = agent.contentCatalog.externalSessions.changes()

    await agent.setImportRoots([:])

    let change = await Self.firstChange(of: changes) { $0 == .domainRemoved(.claudeCode) }
    #expect(change != nil)
    #expect(await agent.contentCatalog.externalSessions.stamps().isEmpty)
    await fixture.close()
  }
}
