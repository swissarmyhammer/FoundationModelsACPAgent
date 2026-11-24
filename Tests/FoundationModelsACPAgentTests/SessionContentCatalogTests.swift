import Foundation
import FoundationModelsACP
import FoundationModelsACPAgentTestSupport
import FoundationModelsExtras
import Testing
import ULID

@testable import FoundationModelsACPAgent

/// The sessions part of the content catalog of a host (D214, part 1): one record for each
/// session that the session directory lists, its stamp, and a change stream.
@Suite(.closesHarnesses) struct SessionContentCatalogTests {
  /// The label of the folders of the suite.
  private static let label = "SessionContentCatalogTests"

  /// The tag that a test adds.
  private static let tag = "zebra"

  /// The name that a rename gives.
  private static let newName = "Quokka research"

  /// A scripted agent with one live session.
  ///
  /// - Parameter name: The label of the test.
  /// - Returns: The fixture.
  /// - Throws: The error of the fixture.
  private static func makeFixture(_ name: String) async throws -> ScriptedPromptFixture {
    try await ScriptedPromptFixture.make(script: [.endPass], label: "\(label)-\(name)")
  }

  /// The id of the session of a fixture.
  ///
  /// - Parameter fixture: The fixture.
  /// - Returns: The id.
  /// - Throws: A failed requirement when the id is not a ULID.
  private static func id(of fixture: ScriptedPromptFixture) throws -> ULID {
    try #require(ULID(ulidString: fixture.sessionId.rawValue))
  }

  /// Reads the changes of `stream` until one satisfies `matches`.
  ///
  /// - Parameters:
  ///   - stream: The stream.
  ///   - matches: Tells whether a change is the one wanted.
  /// - Returns: The change, or `nil` when the stream ends first.
  private static func firstChange(
    of stream: AsyncStream<ContentCatalogChange<ULID, SessionContentRecord>>,
    where matches: (ContentCatalogChange<ULID, SessionContentRecord>) -> Bool
  ) async -> ContentCatalogChange<ULID, SessionContentRecord>? {
    for await change in stream where matches(change) {
      return change
    }
    return nil
  }

  // MARK: - The reads

  /// A session with a tag gives a session record with the tag, and a stamp. The tag changes the
  /// stamp.
  @Test func aTaggedSessionGivesARecordWithTheTag() async throws {
    let fixture = try await Self.makeFixture("tag")
    let agent = fixture.harness.agent
    let id = try Self.id(of: fixture)
    let catalog = agent.contentCatalog.sessions
    let before = try #require(try await catalog.stamps()[id])

    _ = try await agent.sessionDirectory.addTags([Self.tag], to: id)

    let record = try #require(try await catalog.record(id))
    #expect(record.tags == [Self.tag])
    #expect(record.folder.standardizedFileURL == fixture.cwd.standardizedFileURL)
    #expect(record.kind == .root)
    #expect(try await catalog.records(of: id) == [record])
    #expect(try await catalog.stamps()[id] != before)
    await fixture.close()
  }

  /// A folder that the `readableFolder` rule of the host refuses gives no record and no stamp.
  @Test func aFolderThatTheRuleRefusesGivesNoRecord() async throws {
    let fixture = try await Self.makeFixture("refused")
    let agent = fixture.harness.agent
    let id = try Self.id(of: fixture)
    let catalog = SessionContentCatalog(
      directory: agent.sessionDirectory, readableFolder: { _ in false },
      removals: agent.contentRemovalFeed)

    #expect(try await catalog.record(id) == nil)
    #expect(try await catalog.records(of: id).isEmpty)
    #expect(try await catalog.stamps().isEmpty)
    await fixture.close()
  }

  // MARK: - The changes

  /// A rename gives a change with the new name.
  @Test func aRenameGivesAChangeWithTheNewName() async throws {
    let fixture = try await Self.makeFixture("rename")
    let agent = fixture.harness.agent
    let id = try Self.id(of: fixture)
    let changes = agent.contentCatalog.sessions.changes()

    _ = try await agent.sessionDirectory.setTitle(Self.newName, of: id)

    let change = await Self.firstChange(of: changes) {
      guard case .changed(id, let records) = $0 else { return false }
      return records.first?.name == Self.newName
    }
    #expect(change != nil)
    await fixture.close()
  }

  /// `session/delete` gives "this domain went away".
  @Test func aDeleteGivesTheRemovalOfTheDomain() async throws {
    let fixture = try await Self.makeFixture("delete")
    let id = try Self.id(of: fixture)
    let changes = fixture.harness.agent.contentCatalog.sessions.changes()

    _ = try await fixture.harness.connection.deleteSession(
      DeleteSessionRequest(sessionId: fixture.sessionId))

    let change = await Self.firstChange(of: changes) {
      if case .domainRemoved(id) = $0 { return true }
      return false
    }
    #expect(change != nil)
    #expect(try await fixture.harness.agent.contentCatalog.sessions.record(id) == nil)
    await fixture.close()
  }
}
